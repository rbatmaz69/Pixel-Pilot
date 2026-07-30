import Testing

@testable import PixelPilotCore

/// The packet layer is where a silent mistake costs the most: a malformed byte
/// produces "the monitor doesn't support DDC", not an error anyone can trace.
/// These run without hardware.
@Suite("DDC packets")
struct DDCPacketTests {
  @Test("Get request matches the wire format")
  func getRequest() {
    // 0x6E ^ 0x82 ^ 0x01 ^ 0x10 == 0xFD
    #expect(DDCPacket.getRequest(.luminance) == [0x82, 0x01, 0x10, 0xFD])
  }

  @Test("Set request matches the wire format")
  func setRequest() {
    let packet = DDCPacket.setRequest(.luminance, value: 50)
    #expect(packet.count == 6)
    #expect(Array(packet[0 ..< 5]) == [0x84, 0x03, 0x10, 0x00, 0x32])
    #expect(packet[5] == 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32)
  }

  /// Regression guard for a real defect in the reference implementation, which
  /// derives packet length by scanning for the last non-zero byte. Brightness
  /// 168 is the value whose checksum computes to exactly zero, so that approach
  /// silently sends a five-byte packet with no checksum at all.
  @Test("A zero checksum does not shorten the packet")
  func zeroChecksumKeepsFullLength() {
    let packet = DDCPacket.setRequest(.luminance, value: 168)
    #expect(packet[5] == 0x00, "precondition: this value is the one that checksums to zero")
    #expect(packet.count == 6)
  }

  @Test("Alternate input source uses the alternate data address")
  func alternateAddress() {
    #expect(VCPCode.inputSource.dataAddress == 0x51)
    #expect(VCPCode.inputSourceAlternate.dataAddress == 0x50)

    let packet = DDCPacket.setRequest(.inputSourceAlternate, value: 17)
    #expect(packet[5] == 0x6E ^ 0x50 ^ 0x84 ^ 0x03 ^ 0xF4 ^ 0x00 ^ 0x11)
  }

  // MARK: - Replies

  /// Builds a well-formed Get VCP Feature reply with a correct trailing checksum.
  private func makeReply(
    vcp: UInt8,
    current: UInt16,
    maximum: UInt16,
    resultCode: UInt8 = 0x00
  ) -> [UInt8] {
    var reply: [UInt8] = [
      0x6E, 0x88, 0x02, resultCode, vcp, 0x00,
      UInt8(maximum >> 8), UInt8(truncatingIfNeeded: maximum),
      UInt8(current >> 8), UInt8(truncatingIfNeeded: current),
      0x00,
    ]
    reply[10] = reply[0 ..< 10].reduce(UInt8(0x50)) { $0 ^ $1 }
    return reply
  }

  @Test("Valid reply decodes current and maximum")
  func parseValidReply() throws {
    let parsed = try DDCPacket.parseReply(
      makeReply(vcp: 0x10, current: 50, maximum: 100), expecting: .luminance
    )
    #expect(parsed.reading == DDCReading(current: 50, maximum: 100))
    #expect(parsed.checksumValid)
    #expect(parsed.reading.fraction == 0.5)
  }

  @Test("Values above one byte survive the round trip")
  func parseWideValues() throws {
    let parsed = try DDCPacket.parseReply(
      makeReply(vcp: 0x62, current: 300, maximum: 1000), expecting: .audioSpeakerVolume
    )
    #expect(parsed.reading == DDCReading(current: 300, maximum: 1000))
  }

  /// A wrong checksum is reported but does not discard the values — enough
  /// panels get this byte wrong that rejecting them would mean no DDC at all on
  /// that hardware.
  @Test("Bad checksum is flagged, not fatal")
  func parseBadChecksum() throws {
    var reply = makeReply(vcp: 0x10, current: 50, maximum: 100)
    reply[10] ^= 0xFF
    let parsed = try DDCPacket.parseReply(reply, expecting: .luminance)
    #expect(parsed.reading.current == 50)
    #expect(!parsed.checksumValid)
  }

  @Test("Result code 1 means the feature is unsupported")
  func parseUnsupported() {
    let reply = makeReply(vcp: 0x62, current: 0, maximum: 0, resultCode: 0x01)
    #expect(throws: DDCError.self) {
      try DDCPacket.parseReply(reply, expecting: .audioSpeakerVolume)
    }
  }

  @Test("A reply echoing a different feature is rejected")
  func parseWrongEcho() {
    let reply = makeReply(vcp: 0x12, current: 50, maximum: 100)
    #expect(throws: DDCError.self) {
      try DDCPacket.parseReply(reply, expecting: .luminance)
    }
  }

  @Test("An all-zero buffer is treated as no response")
  func parseSilence() {
    #expect(throws: DDCError.self) {
      try DDCPacket.parseReply([UInt8](repeating: 0, count: 12), expecting: .luminance)
    }
  }

  @Test("A short buffer is rejected")
  func parseShortBuffer() {
    #expect(throws: DDCError.self) {
      try DDCPacket.parseReply([0x6E, 0x88, 0x02], expecting: .luminance)
    }
  }

  @Test("A nonsense maximum yields no fraction rather than a division by zero")
  func zeroMaximum() {
    #expect(DDCReading(current: 0, maximum: 0).fraction == nil)
  }
}
