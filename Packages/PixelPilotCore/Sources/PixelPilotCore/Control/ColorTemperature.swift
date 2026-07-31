import Foundation

/// A white point as per-channel multipliers, each 0...1.
///
/// Normalised so the largest component is exactly 1. That is not cosmetic: it
/// guarantees warming a display only ever *removes* light. A component above 1
/// would ask the gamma table for output the panel cannot produce, and the
/// hardware's answer to that is to clip — so the highlights would flatten into
/// a single tone while the picture appeared to get brighter.
public struct WhitePoint: Sendable, Equatable, Codable {
  public let red: Double
  public let green: Double
  public let blue: Double

  public static let neutral = WhitePoint(red: 1, green: 1, blue: 1)

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public var isNeutral: Bool { self == .neutral }
}

/// Kelvin to RGB.
///
/// Tanner Helland's approximation of black-body colour, which is the one every
/// piece of software that does this uses. It is a curve fit rather than a
/// colorimetric transform, and that is the right level of precision here: the
/// goal is "warmer" and "cooler" by eye on a panel whose own primaries are
/// unknown and uncalibrated, not a colour-managed conversion. Anything more
/// exact would be false precision on top of a gamma table.
public enum ColorTemperature {
  /// D65, near enough. A display asked for this must be left completely alone —
  /// the neutral white point is the identity, not "a very slight tint".
  public static let neutralKelvin: Double = 6500

  /// The range offered in the interface. Below this it stops looking like a
  /// screen; above it, nothing changes that anyone can see.
  public static let range: ClosedRange<Double> = 2000 ... 9000

  public static func whitePoint(kelvin: Double) -> WhitePoint {
    // Exactly neutral rather than "whatever the fit returns at 6500", because
    // the fit is approximate and a user who sets the slider back to the middle
    // is entitled to a table that is genuinely the identity.
    guard abs(kelvin - neutralKelvin) > 1 else { return .neutral }

    let temperature = min(40000, max(1000, kelvin)) / 100

    let red: Double
    if temperature <= 66 {
      red = 255
    } else {
      red = 329.698_727_446 * pow(temperature - 60, -0.133_204_759_2)
    }

    let green: Double
    if temperature <= 66 {
      green = 99.470_802_586_1 * log(temperature) - 161.119_568_166_1
    } else {
      green = 288.122_169_528_3 * pow(temperature - 60, -0.075_514_849_2)
    }

    let blue: Double
    if temperature >= 66 {
      blue = 255
    } else if temperature <= 19 {
      blue = 0
    } else {
      blue = 138.517_731_223_1 * log(temperature - 10) - 305.044_792_730_7
    }

    return normalised(red: red, green: green, blue: blue)
  }

  private static func normalised(red: Double, green: Double, blue: Double) -> WhitePoint {
    let channels = [red, green, blue].map { min(255, max(0, $0)) }
    // Divide by the largest rather than by 255. Scaling by 255 would darken the
    // display as it warmed, so the warmth control would double as a brightness
    // control — two things on one slider, and the second one unlabelled.
    guard let peak = channels.max(), peak > 0 else { return .neutral }
    return WhitePoint(
      red: channels[0] / peak,
      green: channels[1] / peak,
      blue: channels[2] / peak
    )
  }
}
