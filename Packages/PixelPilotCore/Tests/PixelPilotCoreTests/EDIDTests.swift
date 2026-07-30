import Foundation
import Testing

@testable import PixelPilotCore

@Suite("EDID")
struct EDIDTests {
  /// Assembles a valid 128-byte EDID base block so the parser is tested against
  /// the real layout rather than a fixture nobody can check by eye.
  static func makeBlock(
    manufacturer: String = "SAM",
    productCode: UInt16 = 0x3200,
    serial: UInt32 = 0x0001_E240,
    week: UInt8 = 38,
    year: Int = 2025,
    widthCM: UInt8 = 70,
    heightCM: UInt8 = 39,
    name: String? = "U32T1",
    serialText: String? = nil
  ) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 128)
    block[0 ..< 8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00][...]

    let letters = Array(manufacturer.uppercased().unicodeScalars).map { UInt16($0.value) - 64 }
    let packed = (letters[0] << 10) | (letters[1] << 5) | letters[2]
    block[8] = UInt8(packed >> 8)
    block[9] = UInt8(truncatingIfNeeded: packed)

    block[10] = UInt8(truncatingIfNeeded: productCode)
    block[11] = UInt8(productCode >> 8)
    block[12] = UInt8(truncatingIfNeeded: serial)
    block[13] = UInt8(truncatingIfNeeded: serial >> 8)
    block[14] = UInt8(truncatingIfNeeded: serial >> 16)
    block[15] = UInt8(truncatingIfNeeded: serial >> 24)
    block[16] = week
    block[17] = UInt8(year - 1990)
    block[18] = 1
    block[19] = 4
    block[21] = widthCM
    block[22] = heightCM

    func writeDescriptor(at offset: Int, tag: UInt8, text: String) {
      block[offset + 3] = tag
      var payload = Array(text.utf8.prefix(13))
      if payload.count < 13 {
        payload.append(0x0A)
        payload.append(contentsOf: [UInt8](repeating: 0x20, count: 13 - payload.count))
      }
      block[(offset + 5) ..< (offset + 18)] = payload[...]
    }

    if let name { writeDescriptor(at: 54, tag: 0xFC, text: name) }
    if let serialText { writeDescriptor(at: 72, tag: 0xFF, text: serialText) }

    let sum = block[0 ..< 127].reduce(into: Int(0)) { $0 += Int($1) }
    block[127] = UInt8((256 - (sum % 256)) % 256)
    return block
  }

  @Test("Identifying fields decode correctly")
  func parseFields() throws {
    let edid = try EDID(bytes: Self.makeBlock())
    #expect(edid.manufacturerCode == "SAM")
    #expect(edid.productCode == 0x3200)
    #expect(edid.serialNumber == 0x0001_E240)
    #expect(edid.manufactureWeek == 38)
    #expect(edid.manufactureYear == 2025)
    #expect(edid.version == "1.4")
    #expect(edid.displayName == "U32T1")
    #expect(edid.imageSizeCM?.width == 70)
    #expect(edid.imageSizeCM?.height == 39)
  }

  /// The three-letter code is three 5-bit values, not ASCII. This is the field
  /// most likely to be decoded wrongly and never noticed.
  @Test("Manufacturer code unpacks from 5-bit letters", arguments: ["SAM", "DEL", "IPS", "APP"])
  func manufacturerRoundTrip(code: String) throws {
    let edid = try EDID(bytes: Self.makeBlock(manufacturer: code))
    #expect(edid.manufacturerCode == code)
  }

  @Test("Serial descriptor is read when present")
  func serialDescriptor() throws {
    let edid = try EDID(bytes: Self.makeBlock(serialText: "HNMX500123"))
    #expect(edid.serialText == "HNMX500123")
  }

  @Test("Missing descriptors yield nil, not empty strings")
  func absentDescriptors() throws {
    let edid = try EDID(bytes: Self.makeBlock(name: nil))
    #expect(edid.displayName == nil)
    #expect(edid.serialText == nil)
  }

  @Test("A corrupt checksum is rejected in strict mode and tolerated otherwise")
  func checksumHandling() throws {
    var block = Self.makeBlock()
    block[127] ^= 0x5A

    #expect(throws: EDID.ParseError.self) { try EDID(bytes: block) }

    let lenient = try EDID(bytes: block, strictChecksum: false)
    #expect(lenient.displayName == "U32T1")
  }

  @Test("A missing header signature is rejected")
  func badHeader() {
    var block = Self.makeBlock()
    block[0] = 0x01
    #expect(throws: EDID.ParseError.self) { try EDID(bytes: block) }
  }

  @Test("A truncated block is rejected")
  func tooShort() {
    #expect(throws: EDID.ParseError.self) { try EDID(bytes: [0x00, 0xFF, 0xFF]) }
  }
}

@Suite("DisplayKey")
struct DisplayKeyTests {
  /// The whole point of the key: settings must follow the panel across
  /// reconnects, so the same panel has to hash identically every time.
  @Test("Same panel produces the same key")
  func stability() throws {
    let first = try EDID(bytes: EDIDTests.makeBlock())
    let second = try EDID(bytes: EDIDTests.makeBlock())
    #expect(DisplayKey(edid: first) == DisplayKey(edid: second))
  }

  @Test("Different panels produce different keys")
  func distinctness() throws {
    let base = try EDID(bytes: EDIDTests.makeBlock())
    let otherSerial = try EDID(bytes: EDIDTests.makeBlock(serial: 0x0001_E241))
    let otherModel = try EDID(bytes: EDIDTests.makeBlock(productCode: 0x3201))

    #expect(DisplayKey(edid: base) != DisplayKey(edid: otherSerial))
    #expect(DisplayKey(edid: base) != DisplayKey(edid: otherModel))
  }

  /// Two identical monitors of the same model with a zeroed serial — common on
  /// cheap panels — are genuinely indistinguishable by EDID. Worth pinning so
  /// the limitation is visible rather than discovered later.
  @Test("Identical panels with no serial collide, by design")
  func knownCollision() throws {
    let first = try EDID(bytes: EDIDTests.makeBlock(serial: 0))
    let second = try EDID(bytes: EDIDTests.makeBlock(serial: 0))
    #expect(DisplayKey(edid: first) == DisplayKey(edid: second))
  }

  @Test("The CoreGraphics fallback separates built-in from external")
  func builtinFallback() {
    let builtin = DisplayKey(vendor: 1552, model: 42, serial: 0, isBuiltin: true)
    let external = DisplayKey(vendor: 1552, model: 42, serial: 0, isBuiltin: false)
    #expect(builtin != external)
  }

  @Test("Keys are short and hex-encoded")
  func format() throws {
    let key = DisplayKey(edid: try EDID(bytes: EDIDTests.makeBlock()))
    #expect(key.rawValue.count == 16)
    #expect(key.rawValue.allSatisfy { $0.isHexDigit })
  }
}
