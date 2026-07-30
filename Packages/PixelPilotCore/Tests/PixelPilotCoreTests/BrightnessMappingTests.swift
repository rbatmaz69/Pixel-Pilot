import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Brightness mapping")
struct BrightnessMappingTests {
  @Test("Without extra dimming the slider drives DDC alone")
  func plainMapping() {
    for value in [0.0, 0.25, 0.5, 0.75, 1.0] {
      let split = BrightnessMapping.split(brightness: value, extraDimming: false)
      #expect(split.ddcFraction == value)
      #expect(split.gammaFraction == 1.0, "gamma must stay untouched when extra dimming is off")
    }
  }

  /// With extra dimming on, the top of the slider must still reach a full
  /// backlight — otherwise enabling the feature quietly costs peak brightness.
  @Test("Maximum still means maximum with extra dimming enabled")
  func fullBrightnessIsPreserved() {
    let split = BrightnessMapping.split(brightness: 1.0, extraDimming: true)
    #expect(split.ddcFraction == 1.0)
    #expect(split.gammaFraction == 1.0)
  }

  @Test("At the handover point the backlight is at zero and gamma is clean")
  func handoverPoint() {
    let split = BrightnessMapping.split(
      brightness: BrightnessMapping.extraDimmingSplit, extraDimming: true
    )
    #expect(split.ddcFraction == 0.0)
    #expect(split.gammaFraction == 1.0)
  }

  @Test("Below the handover, gamma takes over and DDC stays at zero")
  func belowHandover() {
    let split = BrightnessMapping.split(brightness: 0.1, extraDimming: true)
    #expect(split.ddcFraction == 0.0)
    #expect(split.gammaFraction < 1.0)
    #expect(split.gammaFraction > GammaRamp.minimumFraction)
  }

  /// The safety property: no input, including zero, may produce a black screen.
  @Test("Zero brightness never blacks the display out")
  func neverFullyBlack() {
    let split = BrightnessMapping.split(brightness: 0.0, extraDimming: true)
    #expect(split.gammaFraction == GammaRamp.minimumFraction)
    #expect(split.gammaFraction > 0)
  }

  /// A slider must not jump. Walking the whole range, neither output may move
  /// backwards.
  @Test("The combined curve is monotonic across the handover")
  func monotonic() {
    var previousDDC = -1.0
    var previousGamma = -1.0

    for step in 0 ... 100 {
      let split = BrightnessMapping.split(brightness: Double(step) / 100.0, extraDimming: true)
      #expect(split.ddcFraction >= previousDDC, "DDC went backwards at \(step)%")
      #expect(split.gammaFraction >= previousGamma, "gamma went backwards at \(step)%")
      previousDDC = split.ddcFraction
      previousGamma = split.gammaFraction
    }
  }

  @Test("Out-of-range input is clamped, not wrapped")
  func clamping() {
    #expect(BrightnessMapping.split(brightness: -5, extraDimming: false).ddcFraction == 0.0)
    #expect(BrightnessMapping.split(brightness: 7, extraDimming: false).ddcFraction == 1.0)
  }
}

@Suite("Gamma ramp")
struct GammaRampTests {
  @Test("An identity ramp maps each entry to itself")
  func identity() {
    let ramp = GammaRamp.linear(fraction: 1.0)
    #expect(ramp.count == 256)
    #expect(ramp.first == 0.0)
    #expect(abs(ramp.last! - 1.0) < 0.0001)
  }

  @Test("Dimming scales the whole ramp")
  func scaling() {
    let ramp = GammaRamp.linear(fraction: 0.5)
    #expect(abs(ramp.last! - 0.5) < 0.0001)
    #expect(abs(ramp[128] - Float(128.0 / 255.0 * 0.5)) < 0.0001)
  }

  @Test("The ramp never descends")
  func monotonic() {
    let ramp = GammaRamp.linear(fraction: 0.3)
    #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
  }

  /// The lockout guard: a user who cannot see the screen cannot undo the setting
  /// that made it invisible.
  @Test("Dimming is floored so the screen never goes fully black")
  func floor() {
    #expect(GammaRamp.clampFraction(0.0) == GammaRamp.minimumFraction)
    #expect(GammaRamp.clampFraction(-1.0) == GammaRamp.minimumFraction)
    #expect(GammaRamp.linear(fraction: 0.0).last! > 0)
  }

  @Test("Values above one are clamped to the identity")
  func ceiling() {
    #expect(GammaRamp.clampFraction(2.0) == 1.0)
  }
}
