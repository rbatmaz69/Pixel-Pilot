import Foundation

/// A MCCS "Virtual Control Panel" feature code — the thing DDC/CI actually
/// addresses on a monitor.
public struct VCPCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  // Features we actually drive.
  public static let luminance = VCPCode(rawValue: 0x10)
  public static let contrast = VCPCode(rawValue: 0x12)
  public static let audioSpeakerVolume = VCPCode(rawValue: 0x62)
  public static let audioMute = VCPCode(rawValue: 0x8D)
  public static let inputSource = VCPCode(rawValue: 0x60)
  public static let powerMode = VCPCode(rawValue: 0xD6)

  // Read during capability probing / shown in diagnostics.
  public static let redGain = VCPCode(rawValue: 0x16)
  public static let greenGain = VCPCode(rawValue: 0x18)
  public static let blueGain = VCPCode(rawValue: 0x1A)
  public static let colorTemperature = VCPCode(rawValue: 0x0C)

  /// LG panels expose a second input-source control on the alternate I2C
  /// offset. Kept because it is the one widely-confirmed exception.
  public static let inputSourceAlternate = VCPCode(rawValue: 0xF4)

  /// The I2C data address this feature is reached at. Everything uses 0x51
  /// except the LG alternate input control.
  public var dataAddress: UInt8 {
    self == .inputSourceAlternate ? 0x50 : 0x51
  }

  public var description: String {
    let name = Self.knownNames[self] ?? "VCP"
    return String(format: "%@ (0x%02X)", name, rawValue)
  }

  private static let knownNames: [VCPCode: String] = [
    .luminance: "Brightness",
    .contrast: "Contrast",
    .audioSpeakerVolume: "Volume",
    .audioMute: "Mute",
    .inputSource: "Input Source",
    .powerMode: "Power Mode",
    .redGain: "Red Gain",
    .greenGain: "Green Gain",
    .blueGain: "Blue Gain",
    .colorTemperature: "Color Temperature",
    .inputSourceAlternate: "Input Source (alt)",
  ]

  /// The features probed once per panel to work out what it supports.
  /// Deliberately short: every entry costs a full DDC round trip.
  public static let probeSet: [VCPCode] = [
    .luminance, .contrast, .audioSpeakerVolume, .audioMute, .inputSource, .powerMode,
  ]
}

/// The result of a Get VCP Feature reply.
public struct DDCReading: Sendable, Equatable {
  public let current: UInt16
  public let maximum: UInt16

  public init(current: UInt16, maximum: UInt16) {
    self.current = current
    self.maximum = maximum
  }

  /// Current value as a 0...1 fraction. Returns nil for a nonsense maximum,
  /// which some panels report for features they don't really implement.
  public var fraction: Double? {
    guard maximum > 0 else { return nil }
    return Double(min(current, maximum)) / Double(maximum)
  }
}

/// Per-display protocol timing.
///
/// These are not universal constants — panels differ widely in how much settling
/// time they need, and getting them wrong shows up as intermittent read failures
/// rather than hard errors. They are persisted per `DisplayKey` so a fussy
/// monitor can be tuned once.
public struct DDCTiming: Sendable, Codable, Equatable {
  /// Settling delay before each I2C transaction.
  public var writeWaitMicroseconds: UInt32
  /// Extra delay between sending a Get VCP request and reading the reply.
  public var readWaitMicroseconds: UInt32
  /// Delay before retrying a failed read.
  public var retryWaitMicroseconds: UInt32
  /// How many times the same write packet is pushed. Some panels drop the first.
  public var writeCycles: Int
  /// Additional read attempts after the first failure.
  public var readRetries: Int

  public static let `default` = DDCTiming(
    writeWaitMicroseconds: 10_000,
    readWaitMicroseconds: 50_000,
    retryWaitMicroseconds: 20_000,
    writeCycles: 2,
    readRetries: 4
  )

  /// For panels that need more room to breathe.
  public static let relaxed = DDCTiming(
    writeWaitMicroseconds: 50_000,
    readWaitMicroseconds: 80_000,
    retryWaitMicroseconds: 40_000,
    writeCycles: 3,
    readRetries: 6
  )

  public init(
    writeWaitMicroseconds: UInt32,
    readWaitMicroseconds: UInt32,
    retryWaitMicroseconds: UInt32,
    writeCycles: Int,
    readRetries: Int
  ) {
    self.writeWaitMicroseconds = writeWaitMicroseconds
    self.readWaitMicroseconds = readWaitMicroseconds
    self.retryWaitMicroseconds = retryWaitMicroseconds
    self.writeCycles = max(1, writeCycles)
    self.readRetries = max(0, readRetries)
  }
}

public enum DDCError: Error, CustomStringConvertible {
  /// The IOAVService symbols could not be resolved, or this display has no
  /// I2C-capable service behind it.
  case unavailable(reason: String)
  case ioError(code: Int32, operation: String)
  /// Reply arrived but did not decode as a Get VCP Feature reply.
  case malformedReply(bytes: [UInt8], detail: String)
  /// The display explicitly answered "I don't support that feature".
  case unsupportedFeature(VCPCode)
  /// Read-back after a write did not match what we asked for.
  case verificationFailed(VCPCode, wrote: UInt16, readBack: UInt16)

  public var description: String {
    switch self {
    case let .unavailable(reason):
      "DDC unavailable: \(reason)"
    case let .ioError(code, operation):
      String(format: "I2C %@ failed (IOReturn 0x%08X)", operation, UInt32(bitPattern: code))
    case let .malformedReply(bytes, detail):
      "Malformed DDC reply (\(detail)): \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))"
    case let .unsupportedFeature(code):
      "Display reports no support for \(code)"
    case let .verificationFailed(code, wrote, readBack):
      "Write verification failed for \(code): wrote \(wrote), read back \(readBack)"
    }
  }
}

/// The narrow surface every DDC backend must provide.
///
/// Everything above this line is transport-agnostic, which is what keeps an
/// Intel `IOFramebufferI2C` backend — or a future replacement for the
/// undocumented IOAVService path — a drop-in.
public protocol DDCTransport: AnyObject, Sendable {
  func read(_ vcp: VCPCode, timing: DDCTiming) throws -> DDCReading
  func write(_ vcp: VCPCode, value: UInt16, timing: DDCTiming) throws
}
