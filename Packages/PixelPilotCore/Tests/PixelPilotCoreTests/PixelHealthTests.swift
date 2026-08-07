import CoreGraphics
import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Normalised rects")
struct NormalisedRectTests {
  @Test("Out-of-range values are clamped, not honoured")
  func initialiserClamps() {
    let escaped = NormalisedRect(x: -1, y: 2, width: 5, height: -5)
    #expect(escaped.x == 0)
    #expect(escaped.y == 1)
    #expect(escaped.maxX <= 1)
    #expect(escaped.maxY <= 1)
  }

  /// A mark with no extent cannot be hit-tested and cannot be exercised, which
  /// are the only two things a mark is for.
  @Test("A rect is never zero-area")
  func neverDegenerate() {
    let flat = NormalisedRect(x: 0.5, y: 0.5, width: 0, height: 0)
    #expect(flat.width >= NormalisedRect.minimumSide)
    #expect(flat.height >= NormalisedRect.minimumSide)
  }

  /// The actual claim the feature makes: a mark placed at 1440p points at the
  /// same piece of glass at 4K.
  @Test("A mark survives a resolution change")
  func survivesResolutionChange() {
    let hd = CGSize(width: 1920, height: 1080)
    let uhd = CGSize(width: 3840, height: 2160)

    let placed = NormalisedRect.normalising(
      CGRect(x: 480, y: 270, width: 8, height: 8), in: hd
    )
    let drawnOnUHD = placed.denormalised(in: uhd)

    #expect(abs(drawnOnUHD.minX - 960) < 1e-9)
    #expect(abs(drawnOnUHD.minY - 540) < 1e-9)
    // Same fraction of the panel, so twice the pixels — which is right: the
    // spot is the same size, the pixels under it are smaller.
    #expect(abs(drawnOnUHD.width - 16) < 1e-9)
  }

  @Test("A click mark is centred on the click")
  func clickMarkIsCentred() {
    let pixels = CGSize(width: 1000, height: 500)
    let mark = NormalisedRect.around(CGPoint(x: 250, y: 100), sidePixels: 10, in: pixels)

    #expect(abs(mark.midX - 0.25) < 1e-9)
    #expect(abs(mark.midY - 0.20) < 1e-9)
    #expect(abs(mark.width * pixels.width - 10) < 1e-9)
    #expect(abs(mark.height * pixels.height - 10) < 1e-9)
  }

  @Test("A click at the very corner still produces a usable mark")
  func cornerClickStaysOnScreen() {
    let mark = NormalisedRect.around(
      .zero, sidePixels: 10, in: CGSize(width: 1000, height: 1000)
    )
    #expect(mark.x >= 0)
    #expect(mark.y >= 0)
    #expect(mark.width >= NormalisedRect.minimumSide)
  }

  @Test("Containment answers inside, outside, and the boundary")
  func containment() {
    let rect = NormalisedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    #expect(rect.contains(CGPoint(x: 0.5, y: 0.5)))
    #expect(rect.contains(CGPoint(x: 0.4, y: 0.4)))
    #expect(rect.contains(CGPoint(x: 0.6, y: 0.6)))
    #expect(!rect.contains(CGPoint(x: 0.61, y: 0.5)))
    #expect(rect.contains(CGPoint(x: 0.61, y: 0.5), tolerance: 0.02))
  }

  @Test("A nudge moves by exactly what it was given, and stops at the edge")
  func nudging() {
    let rect = NormalisedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
    let moved = rect.nudged(dx: 0.01, dy: -0.01)
    #expect(abs(moved.x - 0.51) < 1e-9)
    #expect(abs(moved.y - 0.49) < 1e-9)

    let pinned = rect.nudged(dx: 5, dy: -5)
    #expect(abs(pinned.x - 0.9) < 1e-9)
    #expect(pinned.y == 0)
    // The size is what makes the clamp non-trivial: a nudged mark must stay
    // whole rather than being squashed against the edge.
    #expect(abs(pinned.width - 0.1) < 1e-9)
  }

  @Test("Growing never shrinks a mark and never leaves the screen")
  func growing() {
    let pixels = CGSize(width: 1000, height: 1000)
    let tiny = NormalisedRect.around(CGPoint(x: 500, y: 500), sidePixels: 4, in: pixels)
    let grown = tiny.grown(toAtLeastPixels: 20, in: pixels)
    #expect(abs(grown.width * pixels.width - 20) < 1e-9)
    #expect(abs(grown.midX - tiny.midX) < 1e-9)

    let big = NormalisedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    #expect(big.grown(toAtLeastPixels: 20, in: pixels) == big)

    let corner = NormalisedRect.around(.zero, sidePixels: 2, in: pixels)
      .grown(toAtLeastPixels: 40, in: pixels)
    #expect(corner.x >= 0)
    #expect(corner.maxX <= 1)
  }
}

@Suite("Pixel defects")
struct PixelDefectTests {
  private func mark(
    _ x: Double, _ y: Double, kind: PixelDefect.Kind = .unsure, on pattern: TestPattern? = nil
  ) -> PixelDefect {
    PixelDefect(
      region: NormalisedRect(x: x, y: y, width: 0.05, height: 0.05),
      kind: kind,
      spottedOn: pattern
    )
  }

  /// What somebody just saw already answers the question, so the overlay does
  /// not ask it.
  @Test("The likely kind comes from the pattern it was spotted on")
  func likelyKind() {
    #expect(PixelDefect.Kind.likely(spottedOn: .black) == .stuck)
    #expect(PixelDefect.Kind.likely(spottedOn: .white) == .dead)
    #expect(PixelDefect.Kind.likely(spottedOn: .red) == .dead)
    #expect(PixelDefect.Kind.likely(spottedOn: .green) == .dead)
    #expect(PixelDefect.Kind.likely(spottedOn: .blue) == .dead)
    #expect(PixelDefect.Kind.likely(spottedOn: .greyRamp) == .unsure)
    #expect(PixelDefect.Kind.likely(spottedOn: .checkerboard) == .unsure)
    #expect(PixelDefect.Kind.likely(spottedOn: nil) == .unsure)
  }

  /// Without last-wins, clicking a mark drawn on top of another removes the one
  /// underneath — which looks like the click missed, so it gets repeated.
  @Test("Hit testing takes the topmost mark when two overlap")
  func hitTestLastWins() {
    let under = mark(0.4, 0.4)
    let over = mark(0.42, 0.42)
    let found = PixelDefects.hitTest([under, over], at: CGPoint(x: 0.44, y: 0.44))
    #expect(found?.id == over.id)
  }

  @Test("Hit testing misses cleanly, and the tolerance is what rescues it")
  func hitTestMisses() {
    let only = mark(0.4, 0.4)
    #expect(PixelDefects.hitTest([only], at: CGPoint(x: 0.8, y: 0.8)) == nil)
    #expect(PixelDefects.hitTest([only], at: CGPoint(x: 0.46, y: 0.46)) == nil)
    #expect(
      PixelDefects.hitTest([only], at: CGPoint(x: 0.46, y: 0.46), tolerance: 0.02) != nil
    )
    #expect(PixelDefects.hitTest([], at: CGPoint(x: 0.4, y: 0.4)) == nil)
  }

  @Test("A summary names the kinds rather than counting marks")
  func summary() {
    let defects = [
      mark(0.1, 0.1, kind: .stuck),
      mark(0.2, 0.2, kind: .stuck),
      mark(0.3, 0.3, kind: .dead),
    ]
    #expect(PixelDefects.summary(defects) == "2 stuck, 1 dead")
    #expect(PixelDefects.summary([]).isEmpty)
  }

  /// A screen of dead pixels exercises nothing, and the sheet has to be able to
  /// say so rather than running for ten minutes to no purpose.
  @Test("Dead marks are not worth exercising")
  func worthExercising() {
    let defects = [
      mark(0.1, 0.1, kind: .stuck),
      mark(0.2, 0.2, kind: .dead),
      mark(0.3, 0.3, kind: .unsure),
    ]
    let worth = PixelDefects.worthExercising(defects)
    #expect(worth.count == 2)
    #expect(!worth.contains { $0.kind == .dead })
  }

  /// Reopening a set of marks found on black over a white screen would show
  /// crop marks around nothing.
  @Test("Marks reopen on the pattern most of them were found on")
  func mostCommonPattern() {
    let defects = [
      mark(0.1, 0.1, on: .black),
      mark(0.2, 0.2, on: .black),
      mark(0.3, 0.3, on: .white),
    ]
    #expect(PixelDefects.mostCommonPattern(defects) == .black)
    #expect(PixelDefects.mostCommonPattern([]) == nil)
    #expect(PixelDefects.mostCommonPattern([mark(0.1, 0.1)]) == nil)
  }

  /// A mark placed by a later build on a pattern this one has never heard of
  /// must still decode, and must still show.
  @Test("An unknown pattern name decodes to a mark with no pattern")
  func unknownPatternSurvives() throws {
    let json = """
      {"id":"\(UUID().uuidString)",
       "region":{"x":0.5,"y":0.5,"width":0.01,"height":0.01},
       "kind":"stuck","spottedOn":"inverseRamp","date":0}
      """
    let defect = try JSONDecoder().decode(PixelDefect.self, from: Data(json.utf8))
    #expect(defect.kind == .stuck)
    #expect(defect.pattern == nil)
    #expect(defect.spottedOn == "inverseRamp")
  }

  /// A mark with no place is not a degraded mark, it is nothing — so this is
  /// the one key allowed to throw.
  @Test("A mark with no region refuses to decode")
  func missingRegionThrows() {
    let json = #"{"kind":"stuck"}"#
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PixelDefect.self, from: Data(json.utf8))
    }
  }
}
