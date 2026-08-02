import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Follow curve")
struct FollowCurveTests {
  @Test("Following starts as tracking, not as a preference")
  func identityTracksOneToOne() {
    let curve = FollowCurve.identity
    for source in stride(from: 0.0, through: 1.0, by: 0.1) {
      #expect(abs(curve.target(forSource: source) - source) < 1e-9)
    }
  }

  /// The reason this type is not an offset. An anchor pair sitting in the middle
  /// of the range must not drag the display to black at one end and to full at
  /// the other.
  @Test("Outside the anchors the value holds instead of extrapolating")
  func endsHoldRatherThanExtrapolate() {
    let curve = FollowCurve(
      lower: .init(source: 0.3, target: 0.5),
      upper: .init(source: 0.7, target: 0.9)
    )

    #expect(curve.target(forSource: 0.0) == 0.5)
    #expect(curve.target(forSource: 0.3) == 0.5)
    #expect(curve.target(forSource: 0.7) == 0.9)
    #expect(curve.target(forSource: 1.0) == 0.9)

    // And a straight line in between.
    #expect(abs(curve.target(forSource: 0.5) - 0.7) < 1e-9)
  }

  @Test("Out-of-range input is clamped rather than trusted")
  func inputIsClamped() {
    let curve = FollowCurve.identity
    #expect(curve.target(forSource: -3) == 0)
    #expect(curve.target(forSource: 42) == 1)
  }

  @Test("Teaching in a dark room moves the lower anchor and leaves the upper one")
  func learningLowMovesTheLowerAnchor() {
    var curve = FollowCurve.identity
    curve.learn(source: 0.15, target: 0.45)

    #expect(curve.lower == FollowCurve.Anchor(source: 0.15, target: 0.45))
    #expect(curve.upper == FollowCurve.Anchor(source: 1, target: 1))
    #expect(curve.target(forSource: 0.15) == 0.45)
    // Taught at one end, unchanged at the other.
    #expect(curve.target(forSource: 1.0) == 1.0)
  }

  @Test("Teaching in a bright room moves the upper anchor and leaves the lower one")
  func learningHighMovesTheUpperAnchor() {
    var curve = FollowCurve.identity
    curve.learn(source: 0.9, target: 0.6)

    #expect(curve.upper == FollowCurve.Anchor(source: 0.9, target: 0.6))
    #expect(curve.lower == FollowCurve.Anchor(source: 0, target: 0))
    #expect(curve.target(forSource: 0.9) == 0.6)
    #expect(curve.target(forSource: 1.0) == 0.6)
  }

  @Test("A taught value is reproduced exactly when the source returns to it")
  func teachingIsReproducible() {
    var curve = FollowCurve.identity
    curve.learn(source: 0.2, target: 0.35)
    curve.learn(source: 0.85, target: 0.95)

    #expect(abs(curve.target(forSource: 0.2) - 0.35) < 1e-9)
    #expect(abs(curve.target(forSource: 0.85) - 0.95) < 1e-9)
  }

  /// Two lessons at nearly the same ambient level must not collapse the curve
  /// into a vertical line, where a flicker of the sensor swings the monitor
  /// end to end.
  @Test("Anchors taught close together keep their minimum separation")
  func anchorsCannotCollapse() {
    var curve = FollowCurve.identity
    curve.learn(source: 0.5, target: 0.4)
    curve.learn(source: 0.52, target: 0.9)

    #expect(curve.upper.source - curve.lower.source >= FollowCurve.minimumSeparation - 1e-9)
  }

  @Test("Separation survives teaching at both extremes")
  func separationSurvivesTheEnds() {
    for pair in [(1.0, 0.99), (0.0, 0.01), (0.97, 1.0)] {
      var curve = FollowCurve.identity
      curve.learn(source: pair.0, target: 0.5)
      curve.learn(source: pair.1, target: 0.2)

      #expect(curve.upper.source - curve.lower.source >= FollowCurve.minimumSeparation - 1e-9)
      // And it still answers, rather than dividing by a span of zero.
      #expect(curve.target(forSource: 0.5).isFinite)
    }
  }

  @Test("Anchors clamp the values they are built from")
  func anchorsClampTheirOwnValues() {
    let anchor = FollowCurve.Anchor(source: 5, target: -2)
    #expect(anchor.source == 1)
    #expect(anchor.target == 0)
  }

  /// The rule the whole `Preferences` file is written around: a key an older
  /// build never wrote must degrade, not throw.
  @Test("A curve missing from stored settings decodes as identity")
  func missingKeysDecodeAsIdentity() throws {
    let curve = try JSONDecoder().decode(FollowCurve.self, from: Data("{}".utf8))
    #expect(curve == .identity)

    let partial = try JSONDecoder().decode(
      FollowCurve.self, from: Data(#"{"lower":{"source":0.2,"target":0.3}}"#.utf8)
    )
    #expect(partial.lower == FollowCurve.Anchor(source: 0.2, target: 0.3))
    #expect(partial.upper == FollowCurve.identity.upper)
  }

  @Test("A curve survives a round trip through storage")
  func roundTrips() throws {
    var curve = FollowCurve.identity
    curve.learn(source: 0.25, target: 0.6)

    let data = try JSONEncoder().encode(curve)
    #expect(try JSONDecoder().decode(FollowCurve.self, from: data) == curve)
  }
}
