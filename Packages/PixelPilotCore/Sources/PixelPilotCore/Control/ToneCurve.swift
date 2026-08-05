import Foundation

/// The shape of a display's tone curve — how black its blacks go, how bright
/// its whites get, and how the midtones sit between the two.
///
/// This is the third thing the gamma table can be asked for, alongside
/// luminance and white point, and it is the one that changes what a screen
/// *feels* like rather than how much light it puts out. A matte panel scatters
/// ambient light back into its own black level, so its blacks are milkier and
/// its peak white is lower than a glossy panel's. Ink on paper does the same:
/// the darkest mark is never zero and the page is never a light source.
/// Reproducing that is what "paper finish" means here.
///
/// **What it is not.** It does not remove reflections. Gloss is the coating,
/// and no table on the GPU reaches it. The interface says so rather than
/// letting the name imply otherwise.
///
/// The identity — no lift, full ceiling, unit softness — reproduces the plain
/// scaled ramp exactly. That is deliberate and is what lets the existing
/// dimming behaviour stay pinned by the tests it already had.
public struct ToneCurve: Sendable, Equatable, Hashable, Codable {
  /// Ranges, not preferences. Above a fifth of the scale a lift stops looking
  /// like paper and starts looking like fog; below 0.7 a ceiling has become a
  /// brightness control, and there is already a brightness control.
  public static let liftRange: ClosedRange<Double> = 0 ... 0.20
  public static let ceilingRange: ClosedRange<Double> = 0.70 ... 1.0
  public static let softnessRange: ClosedRange<Double> = 0.75 ... 1.25

  /// Where black sits. 0 is the panel's own black.
  public let blackLift: Double
  /// Where white sits. 1 is the panel's own white.
  public let whiteCeiling: Double
  /// The exponent applied before the two are interpolated. Below 1 lifts the
  /// midtones, above 1 sinks them. The lift and the ceiling do the visible
  /// work; this is the fine adjustment on top of them.
  public let softness: Double

  /// Clamps rather than rejects, for the same reason `setDimming` does: these
  /// values arrive from a slider, from stored JSON written by another build,
  /// and from a preset captured on a different machine. A value out of range is
  /// a value to bring into range, not an error to propagate to a display.
  public init(blackLift: Double, whiteCeiling: Double, softness: Double = 1.0) {
    let lift = blackLift.clamped(to: Self.liftRange)
    let ceiling = whiteCeiling.clamped(to: Self.ceilingRange)
    self.blackLift = lift
    // The ceiling is held above the lift so the curve can never invert or
    // flatten to a single tone. The ranges above make this unreachable today —
    // it is here so that widening one of them later cannot produce a display
    // showing one flat grey.
    self.whiteCeiling = max(ceiling, lift + 0.05)
    self.softness = softness.clamped(to: Self.softnessRange)
  }

  /// The panel's own curve, untouched. Reproduces the plain scaled ramp.
  public static let identity = ToneCurve(blackLift: 0, whiteCeiling: 1, softness: 1)

  /// A printed page: whites settle, blacks lift just enough to stop reading as
  /// a hole in the screen.
  public static let paper = ToneCurve(blackLift: 0.05, whiteCeiling: 0.94, softness: 1.00)

  /// What a matte coating does to the same image — more of the above, because
  /// a matte panel scatters more ambient light into its blacks.
  public static let matte = ToneCurve(blackLift: 0.09, whiteCeiling: 0.88, softness: 0.95)

  /// The flattest of the three. Closer to e-paper than to a display.
  public static let ink = ToneCurve(blackLift: 0.13, whiteCeiling: 0.82, softness: 0.92)

  /// The named finishes, in the order the picker shows them.
  public static let named: [(name: String, curve: ToneCurve)] = [
    ("Paper", .paper),
    ("Matte", .matte),
    ("Ink", .ink),
  ]

  public var isIdentity: Bool { self == .identity }

  /// The name of the finish this curve is, or `nil` once it has been nudged by
  /// hand. The picker uses it to show which named finish is selected without
  /// having to store a second value that could disagree with the numbers.
  public var namedFinish: String? {
    Self.named.first { $0.curve == self }?.name
  }

  /// The curve itself, for an input in 0...1.
  ///
  /// Kept here rather than inline in `GammaRamp` so it can be tested as maths,
  /// which is the same split `GammaRamp` already makes from `GammaDimmer`.
  public func value(at fraction: Double) -> Double {
    let input = min(1, max(0, fraction))
    let shaped = softness == 1 ? input : pow(input, softness)
    return blackLift + (whiteCeiling - blackLift) * shaped
  }

  /// Written by hand for the reason spelled out on `DisplaySettings.init(from:)`:
  /// this is stored inside a settings blob whose decode failure is swallowed
  /// with `try?`, so a fourth field added later must decode as absent rather
  /// than throw and take the display's whole configuration with it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = ToneCurve.identity
    self.init(
      blackLift: try container.decodeIfPresent(Double.self, forKey: .blackLift)
        ?? fallback.blackLift,
      whiteCeiling: try container.decodeIfPresent(Double.self, forKey: .whiteCeiling)
        ?? fallback.whiteCeiling,
      softness: try container.decodeIfPresent(Double.self, forKey: .softness)
        ?? fallback.softness
    )
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, self))
  }
}
