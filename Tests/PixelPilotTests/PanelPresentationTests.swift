import CoreGraphics
import Testing

@testable import PixelPilot

@Suite("Panel presentation")
@MainActor
struct PanelPresentationTests {
  /// The panel at rest: 320 wide, hanging under the menu bar.
  private let target = CGRect(x: 500, y: 600, width: 320, height: 400)

  @Test("At rest the panel is exactly where it was placed")
  func restIsExact() {
    let frame = PanelPresentation.frame(progress: 1, target: target)
    #expect(frame == target)
  }

  /// The reason this was rewritten. Scaling the width made the contents spring
  /// sideways, and a slider or a readout has exactly one correct width — every
  /// other width is a distortion of it, not a smaller version of it.
  @Test("The width never changes, at any point in the movement")
  func widthIsConstant() {
    for progress in stride(from: -0.3, through: 1.3, by: 0.05) {
      let frame = PanelPresentation.frame(progress: CGFloat(progress), target: target)
      #expect(frame.width == target.width)
      #expect(frame.minX == target.minX)
    }
  }

  /// A partly open panel is a partly revealed one, so the edge it is revealed
  /// from must not move.
  @Test("The top edge stays pinned under the status item")
  func topEdgeIsPinned() {
    for progress in stride(from: -0.3, through: 1.3, by: 0.05) {
      let frame = PanelPresentation.frame(progress: CGFloat(progress), target: target)
      #expect(abs(frame.maxY - target.maxY) < 1e-9)
    }
  }

  @Test("Rolled up, the panel is a sliver rather than nothing")
  func collapsedIsSmallButPresent() {
    let frame = PanelPresentation.frame(progress: 0, target: target)
    // Never zero: a window with no pixels has nothing to blur behind it and
    // blinks out a frame early.
    #expect(frame.height > 0)
    #expect(frame.height < target.height * 0.1)
  }

  @Test("The panel only ever grows as it opens")
  func heightIsMonotonicWhileOpening() {
    var previous: CGFloat = 0
    for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
      let height = PanelPresentation.frame(progress: CGFloat(progress), target: target).height
      #expect(height >= previous)
      previous = height
    }
  }

  /// The spring arrives slightly too tall and settles back. That is the point
  /// of it, so overshoot must not be clamped away.
  @Test("Overshoot is allowed through")
  func overshootIsNotClamped() {
    let overshot = PanelPresentation.frame(progress: 1.1, target: target)
    #expect(overshot.height > target.height)
    // And it hangs off the bottom, not the top.
    #expect(abs(overshot.maxY - target.maxY) < 1e-9)
    #expect(overshot.minY < target.minY)
  }

  /// A spring can dip below zero on the way out. A negative height is not a
  /// shorter window, it is an inverted one.
  @Test("Undershoot never inverts the panel")
  func undershootStaysPositive() {
    for progress in stride(from: -0.4, through: 0.0, by: 0.05) {
      let frame = PanelPresentation.frame(progress: CGFloat(progress), target: target)
      #expect(frame.height > 0)
    }
  }

  /// The contents are revealed, not resized. Squashing them while the panel
  /// unrolls is the thing this whole arrangement exists to avoid.
  @Test("The contents are never squashed while opening")
  func contentIsNeverSquashed() {
    for progress in stride(from: -0.3, through: 1.0, by: 0.05) {
      let frame = PanelPresentation.frame(progress: CGFloat(progress), target: target)
      #expect(PanelPresentation.contentStretch(frame: frame, target: target) == 1)
    }
  }

  /// And on the way past, they stretch exactly as far as the window did — so
  /// there is never a band of empty tint under the last row.
  @Test("The contents stretch to fill an overshooting window")
  func contentStretchesOnOvershoot() {
    let overshot = PanelPresentation.frame(progress: 1.08, target: target)
    let stretch = PanelPresentation.contentStretch(frame: overshot, target: target)

    #expect(stretch > 1)
    #expect(abs(target.height * stretch - overshot.height) < 1e-9)
  }

  @Test("The fade is complete before the movement is")
  func fadeFinishesEarly() {
    #expect(PanelPresentation.alpha(progress: 0) == 0)
    #expect(PanelPresentation.alpha(progress: 0.55) == 1)
    #expect(PanelPresentation.alpha(progress: 1) == 1)
    // And an overshooting spring must not push it past opaque.
    #expect(PanelPresentation.alpha(progress: 1.2) == 1)
  }

  /// A panel pushed away from a screen corner rests somewhere other than
  /// directly under its icon. It must still unroll in place rather than
  /// sliding, which is what the constant width and pinned top edge give it.
  @Test("A panel clamped away from the corner still unrolls in place")
  func clampedPanelUnrollsInPlace() {
    let clamped = CGRect(x: 1600, y: 600, width: 320, height: 400)

    let start = PanelPresentation.frame(progress: 0, target: clamped)
    let end = PanelPresentation.frame(progress: 1, target: clamped)

    #expect(start.minX == end.minX)
    #expect(abs(start.maxY - end.maxY) < 1e-9)
  }
}
