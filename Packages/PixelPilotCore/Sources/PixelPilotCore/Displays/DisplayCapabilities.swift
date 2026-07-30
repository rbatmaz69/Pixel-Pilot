import Foundation

/// What a panel can actually be driven with.
///
/// This exists because "the display answered" and "the display supports this"
/// are different things. Real hardware — the Samsung U32T1 this was developed
/// against, among many others — replies to a volume query with a maximum of
/// 65535 despite having no speakers at all. Taking that at face value produces a
/// UI full of controls that move and do nothing, which is worse than not showing
/// them.
///
/// The MCCS spec calls this out: displays are permitted to return undefined data
/// in the MH/ML fields for features they do not implement.
public struct DisplayCapabilities: Sendable, Codable, Equatable {
  public enum Support: Sendable, Codable, Equatable {
    /// Answered with values we can drive.
    case supported(current: UInt16, maximum: UInt16)
    /// Answered, but the answer does not describe a usable control.
    case implausible(current: UInt16, maximum: UInt16, reason: String)
    /// The display explicitly declined the feature.
    case unsupported
    /// No usable reply — timeout, malformed data, bus error.
    case unreachable(String)

    public var isUsable: Bool {
      if case .supported = self { return true }
      return false
    }

    public var reading: DDCReading? {
      switch self {
      case let .supported(current, maximum), let .implausible(current, maximum, _):
        DDCReading(current: current, maximum: maximum)
      case .unsupported, .unreachable:
        nil
      }
    }
  }

  public var features: [VCPCode: Support]
  /// When this probe was taken. Probing costs a DDC round trip per feature, so
  /// the result is cached rather than repeated.
  public var probedAt: Date

  public init(features: [VCPCode: Support] = [:], probedAt: Date = Date()) {
    self.features = features
    self.probedAt = probedAt
  }

  public func support(for vcp: VCPCode) -> Support {
    features[vcp] ?? .unreachable("not probed")
  }

  public func isUsable(_ vcp: VCPCode) -> Bool { support(for: vcp).isUsable }

  // MARK: - Probing

  /// Reads every feature in `VCPCode.probeSet` once and classifies the answers.
  ///
  /// Intended to run exactly once per panel, at first contact, with the result
  /// persisted against its `DisplayKey`. It is far too slow — a full DDC round
  /// trip each, tens of milliseconds apiece — to sit anywhere near a UI update.
  public static func probe(
    transport: any DDCTransport,
    timing: DDCTiming = .default,
    features: [VCPCode] = VCPCode.probeSet,
    log: DiagnosticsLog? = nil
  ) -> DisplayCapabilities {
    var result: [VCPCode: Support] = [:]

    for vcp in features {
      do {
        let reading = try transport.read(vcp, timing: timing)
        result[vcp] = classify(reading, for: vcp)
      } catch let error as DDCError {
        result[vcp] = switch error {
        case .unsupportedFeature: .unsupported
        default: .unreachable("\(error)")
        }
      } catch {
        result[vcp] = .unreachable("\(error)")
      }
    }

    let usable = result.filter { $0.value.isUsable }.keys.map(\.description).sorted()
    log?.record(.info("Capabilities: \(usable.isEmpty ? "none usable" : usable.joined(separator: ", "))"))

    return DisplayCapabilities(features: result)
  }

  /// Continuous controls above this maximum are treated as unimplemented.
  ///
  /// MCCS continuous controls are almost always 0...100, occasionally 0...255,
  /// rarely up to 0...1000. A maximum in the tens of thousands — 65535 above all
  /// — is uninitialised memory, not a control.
  private static let plausibleContinuousMaximum: UInt16 = 1000

  static func classify(_ reading: DDCReading, for vcp: VCPCode) -> Support {
    // Checked before anything type-specific: 0xFFFF is the signature of a field
    // the firmware never filled in, and it appears on enumerated controls too.
    // Without this, a display that has no speakers still passes the mute check,
    // because a garbage current value of 1 happens to mean "muted".
    guard reading.maximum != UInt16.max else {
      return .implausible(
        current: reading.current, maximum: reading.maximum,
        reason: "maximum is 0xFFFF — feature not implemented"
      )
    }

    switch vcp {
    case .audioMute:
      // 1 = muted, 2 = unmuted. Anything else means the field is not real.
      guard reading.current == 1 || reading.current == 2 else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "mute reported \(reading.current), expected 1 or 2"
        )
      }
      return .supported(current: reading.current, maximum: 2)

    case .powerMode:
      // 1 = on, 2 = standby, 3 = suspend, 4 = off, 5 = hard off.
      guard (1 ... 5).contains(reading.current) else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "power mode reported \(reading.current), expected 1...5"
        )
      }
      return .supported(current: reading.current, maximum: 5)

    case .inputSource, .inputSourceAlternate:
      // An enumeration: the maximum is not a range, so only the current value
      // is meaningful. Zero means nothing is selected, which cannot be true.
      guard reading.current > 0 else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "no input source reported"
        )
      }
      return .supported(current: reading.current, maximum: reading.maximum)

    default:
      // Continuous controls: brightness, contrast, volume, gains.
      guard reading.maximum > 0 else {
        return .implausible(
          current: reading.current, maximum: reading.maximum, reason: "maximum is zero"
        )
      }
      guard reading.maximum <= plausibleContinuousMaximum else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "maximum \(reading.maximum) is out of range for a continuous control"
        )
      }
      guard reading.current <= reading.maximum else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "current \(reading.current) exceeds maximum \(reading.maximum)"
        )
      }
      return .supported(current: reading.current, maximum: reading.maximum)
    }
  }
}

/// Without this, a `[VCPCode: Support]` dictionary encodes as a flat array of
/// alternating keys and values — valid, but unreadable in a preferences file and
/// fragile to hand-edit when debugging a misbehaving panel.
extension VCPCode: CodingKeyRepresentable {
  public var codingKey: any CodingKey {
    StringCodingKey(String(format: "0x%02X", rawValue))
  }

  public init?<T: CodingKey>(codingKey: T) {
    let text = codingKey.stringValue
    let hex = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
    guard let value = UInt8(hex, radix: 16) else { return nil }
    self.init(rawValue: value)
  }

  private struct StringCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { self.stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}
