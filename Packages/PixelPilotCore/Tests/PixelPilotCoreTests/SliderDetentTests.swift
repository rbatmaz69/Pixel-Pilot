import Testing

@testable import PixelPilotCore

@Suite("Slider detents")
struct SliderDetentTests {
  private let quarters = SliderDetents.quarters

  @Test("A position on a detent finds it")
  func findsExact() {
    #expect(SliderDetents.nearest(to: 0.5, among: quarters, tolerance: 0.02) == 0.5)
  }

  @Test("A position just inside the tolerance finds it")
  func findsWithinTolerance() {
    #expect(SliderDetents.nearest(to: 0.515, among: quarters, tolerance: 0.02) == 0.5)
  }

  @Test("A position outside the tolerance finds nothing")
  func missesOutsideTolerance() {
    #expect(SliderDetents.nearest(to: 0.53, among: quarters, tolerance: 0.02) == nil)
  }

  /// The two ends are detents like any other, and they are also where the
  /// existing end-stop latch fires. Both may happen at once; neither may be
  /// missed.
  @Test("Both ends are reachable")
  func endsAreDetents() {
    #expect(SliderDetents.nearest(to: 0, among: quarters, tolerance: 0.02) == 0)
    #expect(SliderDetents.nearest(to: 1, among: quarters, tolerance: 0.02) == 1)
  }

  @Test("The nearest detent wins, not the first one listed")
  func picksNearest() {
    // 0.3 sits inside a wide tolerance around both 0.25 and 0.5.
    #expect(SliderDetents.nearest(to: 0.3, among: quarters, tolerance: 0.3) == 0.25)
    #expect(SliderDetents.nearest(to: 0.3, among: [0.5, 0.25], tolerance: 0.3) == 0.25)
  }

  /// Exactly between two marks the answer has to come from the numbers, not
  /// from how the array happened to be sorted — otherwise the same drag ticks
  /// differently depending on the call site.
  @Test("A tie settles on the lower detent whatever the order")
  func tiesAreDeterministic() {
    #expect(SliderDetents.nearest(to: 0.375, among: [0.25, 0.5], tolerance: 0.2) == 0.25)
    #expect(SliderDetents.nearest(to: 0.375, among: [0.5, 0.25], tolerance: 0.2) == 0.25)
  }

  @Test("No detents means no detent")
  func emptyIsNil() {
    #expect(SliderDetents.nearest(to: 0.5, among: [], tolerance: 0.02) == nil)
  }

  /// The tolerance a zero-width track produces. It must mean "nothing is
  /// reachable" — the opposite reading would put every detent under the
  /// pointer at once.
  @Test("A tolerance of zero reaches nothing, including an exact hit")
  func zeroToleranceIsNil() {
    #expect(SliderDetents.nearest(to: 0.5, among: quarters, tolerance: 0) == nil)
    #expect(SliderDetents.nearest(to: 0.5, among: quarters, tolerance: -1) == nil)
  }

  @Test("Detents outside the track are ignored rather than clamped")
  func ignoresOutOfRangeDetents() {
    #expect(SliderDetents.nearest(to: 0.02, among: [-0.5, 1.5], tolerance: 0.6) == nil)
    #expect(SliderDetents.nearest(to: 0.02, among: [-0.5, 0.0], tolerance: 0.6) == 0)
  }

  // MARK: - Tolerance

  /// The point of deriving the tolerance: the same physical distance on any
  /// slider width. A 4 pt detent is twice the fraction on a track half as wide.
  @Test("Tolerance scales with the track, so the feel does not")
  func toleranceScales() {
    let narrow = SliderDetents.tolerance(points: 4, travel: 200)
    let wide = SliderDetents.tolerance(points: 4, travel: 400)
    #expect(narrow == 0.02)
    #expect(wide == 0.01)
  }

  @Test("A track with no room yields no tolerance")
  func degenerateTrack() {
    #expect(SliderDetents.tolerance(points: 4, travel: 0) == 0)
    #expect(SliderDetents.tolerance(points: 4, travel: -10) == 0)
    #expect(SliderDetents.tolerance(points: 0, travel: 200) == 0)
  }

  @Test("Tolerance never exceeds the whole track")
  func toleranceClamps() {
    #expect(SliderDetents.tolerance(points: 400, travel: 100) == 1)
  }
}
