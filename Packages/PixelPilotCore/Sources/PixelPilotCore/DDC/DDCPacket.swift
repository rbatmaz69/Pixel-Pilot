import Foundation

/// Pure DDC/CI packet construction and parsing.
///
/// Kept free of IOKit on purpose: this is the part most likely to be subtly
/// wrong, and it is the part that can be unit-tested without a monitor attached.
public enum DDCPacket {
  /// Destination address of the display, used as the checksum seed for host →
  /// display packets. This is the 7-bit 0x37 address shifted left by one; the
  /// I2C layer itself is still handed the unshifted 0x37.
  static let displayAddress: UInt8 = 0x6E
  /// Destination address of the host, used as the checksum seed for replies.
  static let hostAddress: UInt8 = 0x50
  /// The 7-bit I2C address passed to `IOAVServiceRead/WriteI2C`.
  public static let chipAddress: UInt32 = 0x37

  private static let getVCPOpcode: UInt8 = 0x01
  private static let setVCPOpcode: UInt8 = 0x03
  private static let getVCPReplyOpcode: UInt8 = 0x02

  /// Length of the Get VCP Feature reply we expect back, in bytes.
  public static let replyLength = 11

  /// Builds a "Get VCP Feature" request.
  ///
  /// Note the checksum seed omits the source address here. That asymmetry with
  /// `setRequest` looks like a mistake but is what real displays accept — it
  /// matches the reference implementations that are known to work in the field.
  public static func getRequest(_ vcp: VCPCode) -> [UInt8] {
    var packet: [UInt8] = [0x80 | 0x02, getVCPOpcode, vcp.rawValue, 0x00]
    packet[3] = displayAddress ^ packet[0] ^ packet[1] ^ packet[2]
    return packet
  }

  /// Builds a "Set VCP Feature" request. `value` is transmitted big-endian.
  public static func setRequest(_ vcp: VCPCode, value: UInt16) -> [UInt8] {
    var packet: [UInt8] = [
      0x80 | 0x04,
      setVCPOpcode,
      vcp.rawValue,
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value),
      0x00,
    ]
    packet[5] = displayAddress ^ vcp.dataAddress
      ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
    return packet
  }

  public struct ParsedReply: Sendable, Equatable {
    public let reading: DDCReading
    /// False when the trailing checksum byte disagrees with the payload. The
    /// reply is still returned: a fair number of panels compute this wrong while
    /// reporting perfectly good values, so the decision to trust it belongs to
    /// the caller, not here.
    public let checksumValid: Bool
  }

  /// Decodes a Get VCP Feature reply.
  ///
  /// Layout: `6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>`
  public static func parseReply(_ bytes: [UInt8], expecting vcp: VCPCode) throws -> ParsedReply {
    guard bytes.count >= replyLength else {
      throw DDCError.malformedReply(bytes: bytes, detail: "only \(bytes.count) bytes")
    }
    let reply = Array(bytes[0 ..< replyLength])

    // An all-zero buffer is what a display that never answered looks like.
    guard reply.contains(where: { $0 != 0 }) else {
      throw DDCError.malformedReply(bytes: reply, detail: "no response")
    }
    guard reply[2] == getVCPReplyOpcode else {
      throw DDCError.malformedReply(
        bytes: reply,
        detail: String(format: "opcode 0x%02X, expected 0x02", reply[2])
      )
    }
    // Result code 0x01 is the display explicitly declining the feature.
    guard reply[3] == 0x00 else {
      throw DDCError.unsupportedFeature(vcp)
    }
    guard reply[4] == vcp.rawValue else {
      throw DDCError.malformedReply(
        bytes: reply,
        detail: String(format: "echoed VCP 0x%02X, asked for 0x%02X", reply[4], vcp.rawValue)
      )
    }

    let maximum = (UInt16(reply[6]) << 8) | UInt16(reply[7])
    let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])

    let checksum = reply[0 ..< 10].reduce(hostAddress) { $0 ^ $1 }

    return ParsedReply(
      reading: DDCReading(current: current, maximum: maximum),
      checksumValid: checksum == reply[10]
    )
  }
}
