import CryptoKit
import Foundation

/// A parsed EDID 1.x base block.
///
/// We only decode the fields that actually help us identify a panel and show it
/// to the user. Timing descriptors, chromaticity and extension blocks are
/// deliberately ignored — macOS already owns mode setting.
public struct EDID: Sendable, Equatable {
  /// Three-letter PnP manufacturer code, e.g. `SAM` for Samsung.
  public let manufacturerCode: String
  public let productCode: UInt16
  /// The 32-bit serial from the header. Frequently 0 or a constant per model.
  public let serialNumber: UInt32
  /// Week of manufacture (1...54), or nil when unspecified.
  public let manufactureWeek: UInt8?
  public let manufactureYear: Int
  public let version: String
  /// Physical size in centimetres, when the panel reports it.
  public let imageSizeCM: (width: Int, height: Int)?
  /// Descriptor 0xFC, e.g. `U32T1`.
  public let displayName: String?
  /// Descriptor 0xFF — an actual per-unit serial, when present.
  public let serialText: String?

  /// The raw bytes we were parsed from, kept for diagnostics and hashing.
  public let raw: [UInt8]

  public static func == (lhs: EDID, rhs: EDID) -> Bool { lhs.raw == rhs.raw }

  public enum ParseError: Error, CustomStringConvertible {
    case tooShort(Int)
    case badHeader
    case badChecksum(expected: UInt8, actual: UInt8)

    public var description: String {
      switch self {
      case let .tooShort(n): "EDID is only \(n) bytes, need at least 128"
      case .badHeader: "EDID header signature missing"
      case let .badChecksum(expected, actual):
        "EDID checksum mismatch (expected \(expected), got \(actual))"
      }
    }
  }

  private static let signature: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

  /// Parses the 128-byte base block.
  ///
  /// - Parameter strictChecksum: some displays — and some virtual/DCP-synthesised
  ///   EDIDs — ship a wrong checksum byte while every field we care about is
  ///   fine. Callers that would rather have imperfect data than none can relax
  ///   the check.
  public init(bytes: [UInt8], strictChecksum: Bool = true) throws {
    guard bytes.count >= 128 else { throw ParseError.tooShort(bytes.count) }
    let block = Array(bytes[0 ..< 128])
    guard Array(block[0 ..< 8]) == Self.signature else { throw ParseError.badHeader }

    let sum = block.reduce(into: UInt8(0)) { $0 &+= $1 }
    if sum != 0 {
      let expected = UInt8((256 - (block[0 ..< 127].reduce(into: Int(0)) { $0 += Int($1) } % 256)) % 256)
      if strictChecksum { throw ParseError.badChecksum(expected: expected, actual: block[127]) }
    }

    // Manufacturer: bytes 8-9 big-endian, three 5-bit letters where 1 == 'A'.
    let packed = (UInt16(block[8]) << 8) | UInt16(block[9])
    let letters = [(packed >> 10) & 0x1F, (packed >> 5) & 0x1F, packed & 0x1F].map { value -> Character in
      guard (1 ... 26).contains(value) else { return "?" }
      return Character(UnicodeScalar(UInt8(value) + 64))
    }
    self.manufacturerCode = String(letters)

    self.productCode = UInt16(block[10]) | (UInt16(block[11]) << 8)
    self.serialNumber = UInt32(block[12]) | (UInt32(block[13]) << 8)
      | (UInt32(block[14]) << 16) | (UInt32(block[15]) << 24)
    self.manufactureWeek = (1 ... 54).contains(block[16]) ? block[16] : nil
    self.manufactureYear = Int(block[17]) + 1990
    self.version = "\(block[18]).\(block[19])"

    let widthCM = Int(block[21])
    let heightCM = Int(block[22])
    self.imageSizeCM = (widthCM > 0 && heightCM > 0) ? (widthCM, heightCM) : nil

    self.displayName = Self.descriptorText(in: block, tag: 0xFC)
    self.serialText = Self.descriptorText(in: block, tag: 0xFF)
    self.raw = block
  }

  /// Reads one of the four 18-byte descriptors at offsets 54, 72, 90, 108.
  /// A text descriptor starts with `00 00 00 <tag> 00`; the 13 payload bytes are
  /// terminated by 0x0A and space-padded.
  private static func descriptorText(in block: [UInt8], tag: UInt8) -> String? {
    for offset in stride(from: 54, through: 108, by: 18) {
      guard block[offset] == 0, block[offset + 1] == 0, block[offset + 2] == 0,
            block[offset + 3] == tag, block[offset + 4] == 0
      else { continue }

      let payload = block[(offset + 5) ..< (offset + 18)]
      let terminated = payload.prefix { $0 != 0x0A }
      let text = String(decoding: terminated, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    return nil
  }
}

// MARK: - Stable identity

/// A stable, human-opaque identifier for a physical panel.
///
/// Every persisted per-display setting hangs off this rather than off a
/// `CGDirectDisplayID`, which is reassigned whenever the display graph changes.
/// The key survives replugging, port changes, docking and reboots.
public struct DisplayKey: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }

  /// Derived from the identifying EDID fields only. Deliberately *not* the whole
  /// block: timing descriptors can differ between reads on some panels, which
  /// would make the key unstable.
  public init(edid: EDID) {
    var material = "\(edid.manufacturerCode)|\(edid.productCode)|\(edid.serialNumber)"
    material += "|\(edid.manufactureWeek.map(String.init) ?? "-")|\(edid.manufactureYear)"
    material += "|\(edid.displayName ?? "-")|\(edid.serialText ?? "-")"
    self.init(hashing: material)
  }

  /// Fallback for displays we cannot read an EDID from (notably the built-in
  /// panel, where CoreGraphics is the only source).
  public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool) {
    self.init(hashing: "cg|\(vendor)|\(model)|\(serial)|\(isBuiltin)")
  }

  private init(hashing material: String) {
    let digest = SHA256.hash(data: Data(material.utf8))
    self.rawValue = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  public var description: String { rawValue }
}

/// Encoded as a bare string rather than as `{"rawValue": …}`.
///
/// Preferences are stored as JSON in `UserDefaults`, and one of the design goals
/// is that a user can open them and fix a misconfigured display by hand. Nested
/// wrappers around a single string work against that.
extension DisplayKey: Codable {
  public init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Lets `[DisplayKey: …]` encode as a JSON object.
///
/// Without this, Swift encodes a dictionary with a non-string key as a flat
/// array of alternating keys and values — valid, but unreadable and impossible
/// to edit by hand.
extension DisplayKey: CodingKeyRepresentable {
  public var codingKey: any CodingKey {
    StringCodingKey(stringValue: rawValue)
  }

  public init?<T: CodingKey>(codingKey: T) {
    self.init(rawValue: codingKey.stringValue)
  }
}

private struct StringCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
