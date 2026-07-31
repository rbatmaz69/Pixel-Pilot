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

  // Colour. Probed on demand rather than at first contact — see `colorProbeSet`.
  public static let redGain = VCPCode(rawValue: 0x16)
  public static let greenGain = VCPCode(rawValue: 0x18)
  public static let blueGain = VCPCode(rawValue: 0x1A)
  public static let colorTemperature = VCPCode(rawValue: 0x0C)
  /// The step size 0x0C's value is measured in, in Kelvin.
  public static let colorTemperatureIncrement = VCPCode(rawValue: 0x0B)
  public static let selectColorPreset = VCPCode(rawValue: 0x14)

  /// LG panels expose a second input-source control on the alternate I2C
  /// offset. Kept because it is the one widely-confirmed exception.
  public static let inputSourceAlternate = VCPCode(rawValue: 0xF4)

  /// The I2C data address this feature is reached at. Everything uses 0x51
  /// except the LG alternate input control.
  public var dataAddress: UInt8 {
    self == .inputSourceAlternate ? 0x50 : 0x51
  }

  public var description: String {
    String(format: "%@ (0x%02X)", standardName ?? "unknown", rawValue)
  }

  /// Standard MCCS names, for reading a register scan.
  ///
  /// Worth the table: a scan that prints "VCP (0x0E)" tells you nothing, while
  /// "Clock" immediately identifies a vestigial analog control on a digital
  /// panel. Interpreting a scan without these means guessing.
  private static let knownNames: [UInt8: String] = [
    0x02: "New Control Value",
    0x04: "Restore Factory Defaults",
    0x05: "Restore Factory Brightness/Contrast",
    0x06: "Restore Factory Geometry",
    0x08: "Restore Factory Colour",
    0x0A: "Restore Factory TV Defaults",
    0x0B: "Colour Temperature Increment",
    0x0C: "Colour Temperature Request",
    0x0E: "Clock",
    0x10: "Brightness",
    0x12: "Contrast",
    0x14: "Select Colour Preset",
    0x16: "Video Gain Red",
    0x18: "Video Gain Green",
    0x1A: "Video Gain Blue",
    0x1E: "Auto Setup",
    0x20: "Horizontal Position",
    0x22: "Horizontal Size",
    0x30: "Vertical Position",
    0x32: "Vertical Size",
    0x3E: "Clock Phase",
    0x52: "Active Control",
    0x54: "Performance Preservation",
    0x60: "Input Source",
    0x62: "Audio: Speaker Volume",
    0x63: "Audio: Speaker Select",
    0x64: "Audio: Microphone Volume",
    0x66: "Audio: Jack Connection",
    0x6C: "Video Black Level Red",
    0x6E: "Video Black Level Green",
    0x70: "Video Black Level Blue",
    0x8D: "Audio: Mute",
    0x8F: "Audio: Treble",
    0x91: "Audio: Bass",
    0x93: "Audio: Balance",
    0x94: "Audio: Processor Mode",
    0xA8: "Stereo Video Mode",
    0xAA: "Screen Orientation",
    0xAC: "Horizontal Frequency",
    0xAE: "Vertical Frequency",
    0xB2: "Flat Panel Sub-Pixel Layout",
    0xB4: "Source Timing Mode",
    0xB6: "Display Technology Type",
    0xC6: "Application Enable Key",
    0xC8: "Display Controller ID",
    0xC9: "Display Firmware Level",
    0xCA: "OSD / Button Control",
    0xCC: "OSD Language",
    0xD6: "Power Mode",
    0xDC: "Display Application",
    0xDF: "VCP Version",
    0xF4: "Input Source (alternate address)",
  ]

  /// The standard name, when there is one.
  public var standardName: String? { Self.knownNames[rawValue] }

  /// The features probed once per panel to work out what it supports.
  /// Deliberately short: every entry costs a full DDC round trip.
  public static let probeSet: [VCPCode] = [
    .luminance, .contrast, .audioSpeakerVolume, .audioMute, .inputSource, .powerMode,
  ]

  /// The colour features, kept out of `probeSet` on purpose.
  ///
  /// `probeSet` runs unattended the moment a display is plugged in, and it is
  /// short for a reason. Six more round trips would roughly double how long a
  /// new monitor takes to become usable — for a control most people will never
  /// open. This set is probed on demand instead, the first time the colour card
  /// is looked at, and cached against the panel like the capability string is.
  public static let colorProbeSet: [VCPCode] = [
    .colorTemperatureIncrement, .colorTemperature, .selectColorPreset,
    .redGain, .greenGain, .blueGain,
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
public struct DDCTiming: Sendable, Codable, Hashable {
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

  /// Reads at an explicitly chosen I2C data address.
  ///
  /// Exists for scanning the alternate address 0x50, where some vendors park
  /// controls that are absent from 0x51. Separate from `read(_:timing:)`
  /// because the address normally follows from the feature — only a scan has
  /// reason to override it.
  func read(_ vcp: VCPCode, at dataAddress: UInt8, timing: DDCTiming) throws -> DDCReading
}

public extension DDCTransport {
  /// Backends with no notion of a data address ignore the override.
  func read(_ vcp: VCPCode, at dataAddress: UInt8, timing: DDCTiming) throws -> DDCReading {
    try read(vcp, timing: timing)
  }
}
