import Testing

@testable import PixelPilotCore

@Suite("Colour temperature")
struct ColorTemperatureTests {
  /// The property everything else depends on. If the middle of the slider is
  /// not the identity, the app is tinting a display that was asked to be left
  /// alone — and doing it every time it reasserts gamma after a wake.
  @Test("Neutral is exactly the identity")
  func neutralIsIdentity() {
    #expect(ColorTemperature.whitePoint(kelvin: ColorTemperature.neutralKelvin) == .neutral)
    #expect(ColorTemperature.whitePoint(kelvin: 6500).isNeutral)
  }

  @Test("Warmer means less blue")
  func warmerLosesBlue() {
    let warm = ColorTemperature.whitePoint(kelvin: 2700)
    let neutral = ColorTemperature.whitePoint(kelvin: 6500)
    #expect(warm.blue < neutral.blue)
    #expect(warm.red >= warm.green)
    #expect(warm.green > warm.blue)
  }

  @Test("Blue falls monotonically as the temperature drops")
  func blueIsMonotonic() {
    var previous = Double.infinity
    for kelvin in stride(from: 9000.0, through: 2000.0, by: -250) {
      let point = ColorTemperature.whitePoint(kelvin: kelvin)
      #expect(point.blue <= previous + 1e-9, "blue rose while cooling to \(kelvin) K")
      previous = point.blue
    }
  }

  @Test("Cooler means less red")
  func coolerLosesRed() {
    let cool = ColorTemperature.whitePoint(kelvin: 9000)
    #expect(cool.blue >= cool.green)
    #expect(cool.red < 1.0)
  }

  /// The clipping guarantee. A component above 1 asks the panel for output it
  /// cannot make, and the hardware answers by flattening the highlights.
  @Test("No component ever exceeds one, anywhere in the range")
  func neverExceedsUnity() {
    for kelvin in stride(from: 1000.0, through: 20000.0, by: 100) {
      let point = ColorTemperature.whitePoint(kelvin: kelvin)
      for channel in [point.red, point.green, point.blue] {
        #expect(channel <= 1.0, "component \(channel) above unity at \(kelvin) K")
        #expect(channel >= 0.0, "negative component at \(kelvin) K")
      }
    }
  }

  /// The other half of normalising to the peak rather than to 255: warming must
  /// not double as a brightness control.
  @Test("Some channel is always at full, so warmth does not dim")
  func peakIsAlwaysUnity() {
    for kelvin in stride(from: 2000.0, through: 9000.0, by: 100) {
      let point = ColorTemperature.whitePoint(kelvin: kelvin)
      let peak = max(point.red, max(point.green, point.blue))
      #expect(abs(peak - 1.0) < 1e-9, "peak was \(peak) at \(kelvin) K")
    }
  }

  @Test("Absurd temperatures clamp rather than produce nonsense")
  func clampsExtremes() {
    let cold = ColorTemperature.whitePoint(kelvin: 0)
    let hot = ColorTemperature.whitePoint(kelvin: 1_000_000)
    #expect(cold == ColorTemperature.whitePoint(kelvin: 1000))
    #expect(hot == ColorTemperature.whitePoint(kelvin: 40000))
    #expect(cold.red == 1.0, "the coldest end is still a colour, not black")
  }
}
