import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Tone curve")
struct ToneCurveTests {
  /// What the whole change rests on: with no finish, the curve is `y = x`, so
  /// every ramp the app produced before is the ramp it produces now.
  @Test("The identity curve is the line it claims to be")
  func identityIsLinear() {
    for step in 0 ... 10 {
      let x = Double(step) / 10
      #expect(abs(ToneCurve.identity.value(at: x) - x) < 1e-12)
    }
    #expect(ToneCurve.identity.isIdentity)
  }

  @Test("A finish maps black to the lift and white to the ceiling")
  func endpointsAreTheLiftAndCeiling() {
    let curve = ToneCurve.paper
    #expect(abs(curve.value(at: 0) - curve.blackLift) < 1e-12)
    #expect(abs(curve.value(at: 1) - curve.whiteCeiling) < 1e-12)
  }

  @Test("The curve never goes backwards")
  func curveIsMonotonic() {
    for curve in ToneCurve.named.map(\.curve) {
      var previous = -1.0
      for step in 0 ... 100 {
        let value = curve.value(at: Double(step) / 100)
        #expect(value >= previous)
        previous = value
      }
    }
  }

  /// These values arrive from a slider, from stored JSON another build wrote,
  /// and from a preset captured on a machine that is not this one. All three
  /// have to be brought into range rather than trusted.
  @Test("Out-of-range values are clamped, not honoured")
  func initialiserClamps() {
    let tooMuch = ToneCurve(blackLift: 5, whiteCeiling: 5, softness: 5)
    #expect(tooMuch.blackLift == ToneCurve.liftRange.upperBound)
    #expect(tooMuch.whiteCeiling == ToneCurve.ceilingRange.upperBound)
    #expect(tooMuch.softness == ToneCurve.softnessRange.upperBound)

    let tooLittle = ToneCurve(blackLift: -5, whiteCeiling: -5, softness: -5)
    #expect(tooLittle.blackLift == ToneCurve.liftRange.lowerBound)
    #expect(tooLittle.whiteCeiling == ToneCurve.ceilingRange.lowerBound)
    #expect(tooLittle.softness == ToneCurve.softnessRange.lowerBound)
  }

  /// Unreachable through the ranges as they stand. Pinned anyway, because the
  /// thing it prevents — a display showing one flat grey — is what widening one
  /// of those ranges later would otherwise buy.
  @Test("The ceiling is always held above the lift")
  func ceilingStaysAboveLift() {
    let inverted = ToneCurve(blackLift: 0.20, whiteCeiling: 0.70, softness: 1)
    #expect(inverted.whiteCeiling > inverted.blackLift)
  }

  @Test("A named finish knows its own name, and stops claiming it once nudged")
  func namedFinishIsExact() {
    #expect(ToneCurve.paper.namedFinish == "Paper")
    #expect(ToneCurve.matte.namedFinish == "Matte")
    #expect(ToneCurve.ink.namedFinish == "Ink")
    #expect(ToneCurve.identity.namedFinish == nil)

    let nudged = ToneCurve(
      blackLift: ToneCurve.paper.blackLift + 0.01,
      whiteCeiling: ToneCurve.paper.whiteCeiling,
      softness: ToneCurve.paper.softness
    )
    #expect(nudged.namedFinish == nil)
  }

  @Test("A curve survives a round trip through JSON")
  func roundTrips() throws {
    let data = try JSONEncoder().encode(ToneCurve.matte)
    #expect(try JSONDecoder().decode(ToneCurve.self, from: data) == ToneCurve.matte)
  }

  /// This lives inside a settings blob whose decode failure is swallowed with
  /// `try?`. A key an older build never wrote must decode as absent rather than
  /// throw, or one missing field takes every setting behind it.
  @Test("A payload missing a field falls back instead of throwing")
  func missingFieldDegrades() throws {
    let partial = Data(#"{"blackLift":0.09,"whiteCeiling":0.88}"#.utf8)
    let decoded = try JSONDecoder().decode(ToneCurve.self, from: partial)

    #expect(decoded.blackLift == 0.09)
    #expect(decoded.whiteCeiling == 0.88)
    #expect(decoded.softness == ToneCurve.identity.softness)
  }

  @Test("A stored value out of range is clamped on the way back in")
  func decodingClamps() throws {
    let wild = Data(#"{"blackLift":9,"whiteCeiling":9,"softness":9}"#.utf8)
    let decoded = try JSONDecoder().decode(ToneCurve.self, from: wild)

    #expect(decoded.blackLift == ToneCurve.liftRange.upperBound)
    #expect(decoded.whiteCeiling == ToneCurve.ceilingRange.upperBound)
  }
}
