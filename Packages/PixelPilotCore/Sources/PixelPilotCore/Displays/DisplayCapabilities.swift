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

  /// What a colour temperature control could conceivably span. Panels offer
  /// roughly 5000–9300 K; this is generous on both sides and still excludes the
  /// nonsense a phantom register produces.
  private static let plausibleKelvin: ClosedRange<Double> = 2000 ... 12000

  /// MCCS 0x0C's base. The value is an offset above this.
  static let colorTemperatureBase: Double = 3000
  /// Assumed step when a display has no readable 0x0B. 50 K is the common one.
  static let defaultColorTemperatureIncrement: Double = 50

  static func impliedKelvinRange(
    maximum: UInt16, increment: Double = defaultColorTemperatureIncrement
  ) -> ClosedRange<Double> {
    let top = colorTemperatureBase + Double(maximum) * increment
    return colorTemperatureBase ... max(colorTemperatureBase, top)
  }

  /// Whether this panel really has RGB gain control.
  ///
  /// All three channels or none. A display that answers for red but not green
  /// is not exposing a colour control — it is a register that happens to reply,
  /// and driving it would tint the picture with no way to put it back. The
  /// shared maximum is the second half of the same argument: three gains on
  /// different scales are not three channels of one control.
  public var hasUsableGains: Bool {
    let gains = [VCPCode.redGain, .greenGain, .blueGain].map { support(for: $0) }
    guard gains.allSatisfy(\.isUsable) else { return false }
    let maxima = Set(gains.compactMap { $0.reading?.maximum })
    return maxima.count == 1
  }

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

    case .colorTemperature:
      // MCCS defines this as an offset above 3000 K, counted in units of the
      // 0x0B increment. The raw number is therefore meaningless on its own —
      // what has to be plausible is the temperature range it implies. A panel
      // whose maximum works out to 40000 K is not describing a colour control.
      guard reading.maximum > 0 else {
        return .implausible(
          current: reading.current, maximum: reading.maximum, reason: "maximum is zero"
        )
      }
      let implied = Self.impliedKelvinRange(maximum: reading.maximum)
      guard Self.plausibleKelvin.contains(implied.lowerBound),
            Self.plausibleKelvin.contains(implied.upperBound)
      else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "range implies \(Int(implied.lowerBound))–\(Int(implied.upperBound)) K, "
            + "which is not a colour temperature control"
        )
      }
      return .supported(current: reading.current, maximum: reading.maximum)

    case .colorTemperatureIncrement:
      // The unit 0x0C is counted in. MCCS allows 1...5000 K per step; anything
      // outside that makes the feature above uninterpretable rather than wrong.
      guard (1 ... 5000).contains(reading.current) else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: "increment of \(reading.current) K is not a usable step size"
        )
      }
      return .supported(current: reading.current, maximum: reading.maximum)

    case .selectColorPreset, .inputSource, .inputSourceAlternate:
      // An enumeration: the maximum is not a range, so only the current value
      // is meaningful. Zero means nothing is selected, which cannot be true.
      guard reading.current > 0 else {
        return .implausible(
          current: reading.current, maximum: reading.maximum,
          reason: vcp == .selectColorPreset
            ? "no colour preset reported"
            : "no input source reported"
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
