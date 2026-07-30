import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Capability string")
struct CapabilityStringTests {
  /// Read verbatim off a Samsung U32T1. Real strings are the only honest test
  /// material here: every panel formats these slightly differently, and this one
  /// already breaks two reasonable assumptions — the model name is bare rather
  /// than wrapped in `model(...)`, and there is a stray space inside `60( …)`.
  static let realWorld = "(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)"
    + "vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 11 12 0F 10) "
    + "AA(01 02) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)"
    + "mccs_ver(2.1)mswhql(1))"

  @Test("A real capability string parses")
  func parsesRealString() {
    let capabilities = CapabilityString(raw: Self.realWorld)
    #expect(capabilities.isUsable)
    #expect(capabilities.type == "lcd")
    #expect(capabilities.mccsVersion == "2.1")
    #expect(capabilities.features.count == 24)
  }

  /// The reason this whole file exists: the input source maximum is 14, while
  /// the display's own list contains 15 and 16. Deriving inputs from the maximum
  /// would write values that switch the monitor to a dead input.
  @Test("Enumerated inputs come from the list, not from the maximum")
  func readsInputSources() {
    let capabilities = CapabilityString(raw: Self.realWorld)
    let inputs = capabilities.values(for: .inputSource)
    #expect(inputs?.sorted() == [0x0F, 0x10, 0x11, 0x12])
    // 0x07 is what this display reports as its current input, yet it is not one
    // of its own declared inputs — which is why the active input cannot be
    // determined and the UI must not claim to know it.
    #expect(inputs?.contains(0x07) == false)
  }

  @Test("Power modes are enumerated too")
  func readsPowerModes() {
    let capabilities = CapabilityString(raw: Self.realWorld)
    #expect(capabilities.values(for: .powerMode)?.sorted() == [0x01, 0x04, 0x05])
  }

  @Test("Features with no value list are still listed")
  func continuousFeaturesHaveNoValues() {
    let capabilities = CapabilityString(raw: Self.realWorld)
    #expect(capabilities.values(for: .luminance) == [])
    #expect(capabilities.values(for: .contrast) == [])
  }

  /// The transport strips these, but the parser must not depend on that: a
  /// trailing NUL made the outer parentheses unrecognisable and caused the whole
  /// string to be swallowed as one unnamed group.
  @Test("Trailing padding does not swallow the whole string")
  func toleratesTrailingPadding() {
    for suffix in ["\0", " ", "\n", "\0\0", " \0 "] {
      let capabilities = CapabilityString(raw: Self.realWorld + suffix)
      #expect(capabilities.features.count == 24, "broken by suffix \(suffix.debugDescription)")
    }
  }

  @Test("Whitespace inside a value list is ignored")
  func toleratesInnerWhitespace() {
    let capabilities = CapabilityString(raw: "(vcp(60( 11  12   0F 10 )))")
    #expect(capabilities.values(for: .inputSource)?.sorted() == [0x0F, 0x10, 0x11, 0x12])
  }

  @Test("Junk yields nothing rather than nonsense")
  func rejectsJunk() {
    #expect(!CapabilityString(raw: "").isUsable)
    #expect(!CapabilityString(raw: "not a capability string").isUsable)
    #expect(!CapabilityString(raw: "(prot(monitor))").isUsable)
  }

  @Test("An unknown input code is labelled by its value, not guessed at")
  func labelsUnknownCodes() {
    #expect(InputSource.name(for: 0x0F) == "DisplayPort 1")
    #expect(InputSource.isStandard(0x0F))
    #expect(InputSource.name(for: 0x7A) == "Input 0x7A")
    #expect(!InputSource.isStandard(0x7A))
  }
}

@Suite("Capability packets")
struct CapabilityPacketTests {
  @Test("The request carries the offset and a matching checksum")
  func buildsRequest() {
    let packet = DDCPacket.capabilitiesRequest(offset: 0x0120, includeSourceAddress: false)
    #expect(packet.count == 5)
    #expect(packet[0] == 0x83, "length byte: three payload bytes with the high bit set")
    #expect(packet[1] == 0xF3)
    #expect(packet[2] == 0x01)
    #expect(packet[3] == 0x20)
    #expect(packet[4] == 0x6E ^ 0x83 ^ 0xF3 ^ 0x01 ^ 0x20)
  }

  @Test("Both checksum conventions are available and differ")
  func checksumConventions() {
    let without = DDCPacket.capabilitiesRequest(offset: 0, includeSourceAddress: false)
    let with = DDCPacket.capabilitiesRequest(offset: 0, includeSourceAddress: true)
    #expect(without[4] != with[4])
    #expect(with[4] == without[4] ^ 0x51)
  }

  /// Builds a well-formed reply so the decoder is tested against the layout
  /// rather than against whatever the one available monitor happens to send.
  private func makeReply(offset: UInt16, payload: [UInt8], corruptChecksum: Bool = false) -> [UInt8] {
    let declared = UInt8(3 + payload.count)
    var reply: [UInt8] = [0x6E, 0x80 | declared, 0xE3,
                          UInt8(offset >> 8), UInt8(offset & 0xFF)]
    reply.append(contentsOf: payload)
    let checksum = reply.reduce(UInt8(0x50)) { $0 ^ $1 }
    reply.append(corruptChecksum ? checksum ^ 0xFF : checksum)
    return reply
  }

  @Test("A fragment decodes with its offset and payload")
  func parsesFragment() throws {
    let payload: [UInt8] = Array("(prot(monitor)".utf8)
    let fragment = try DDCPacket.parseCapabilitiesReply(makeReply(offset: 0, payload: payload))
    #expect(fragment.offset == 0)
    #expect(fragment.bytes == payload)
    #expect(fragment.checksumValid)
    #expect(!fragment.isTerminator)
  }

  @Test("An empty fragment ends the string")
  func detectsTerminator() throws {
    let fragment = try DDCPacket.parseCapabilitiesReply(makeReply(offset: 200, payload: []))
    #expect(fragment.isTerminator)
  }

  /// The bug this guards against: a corrupt fragment spliced into the middle of
  /// the string produces something that still parses, but describes a display
  /// that does not exist.
  @Test("A corrupt fragment is flagged rather than accepted")
  func detectsCorruption() throws {
    let payload: [UInt8] = Array("type(lcd)".utf8)
    let fragment = try DDCPacket.parseCapabilitiesReply(
      makeReply(offset: 0, payload: payload, corruptChecksum: true)
    )
    #expect(!fragment.checksumValid)
  }

  @Test("A reply with the wrong opcode is rejected")
  func rejectsWrongOpcode() {
    var reply = makeReply(offset: 0, payload: [0x41])
    reply[2] = 0x02
    #expect(throws: DDCError.self) {
      try DDCPacket.parseCapabilitiesReply(reply)
    }
  }

  @Test("A silent display is rejected rather than read as an empty string")
  func rejectsSilence() {
    #expect(throws: DDCError.self) {
      try DDCPacket.parseCapabilitiesReply([UInt8](repeating: 0, count: 64))
    }
  }

  @Test("A length that overruns the buffer is rejected")
  func rejectsOverlongDeclaredLength() {
    var reply = makeReply(offset: 0, payload: [0x41, 0x42])
    reply[1] = 0x80 | 60
    #expect(throws: DDCError.self) {
      try DDCPacket.parseCapabilitiesReply(Array(reply.prefix(10)))
    }
  }
}
