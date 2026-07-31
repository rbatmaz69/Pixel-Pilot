import CoreGraphics
import Testing

@testable import PixelPilotCore

@Suite("Display layout")
struct DisplayLayoutTests {
  private let box = CGRect(x: 0, y: 0, width: 200, height: 100)

  @Test("No screens is a valid state")
  func empty() {
    #expect(DisplayLayout.normalize(frames: [], into: box).isEmpty)
  }

  @Test("One screen is centred in the box")
  func single() {
    let rects = DisplayLayout.normalize(
      frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)], into: box, spacing: 0
    )
    #expect(rects.count == 1)
    // 16:9 into a 2:1 box: height-limited, so it fills the height.
    #expect(abs(rects[0].height - 100) < 0.001)
    #expect(abs(rects[0].midX - box.midX) < 0.001)
  }

  @Test("Two side by side stay side by side, in order")
  func horizontal() {
    let rects = DisplayLayout.normalize(
      frames: [
        CGRect(x: 0, y: 0, width: 1000, height: 1000),
        CGRect(x: 1000, y: 0, width: 1000, height: 1000),
      ],
      into: box, spacing: 0
    )
    #expect(rects[0].minX < rects[1].minX)
    #expect(abs(rects[0].minY - rects[1].minY) < 0.001)
  }

  /// The bug this file exists for. AppKit counts up from the bottom of the
  /// desktop and SwiftUI counts down from the top, so a screen placed *above*
  /// the main one has the larger y in AppKit and must come out with the
  /// *smaller* y here.
  @Test("A screen above the main one is drawn above it, not below")
  func verticalFlip() {
    let rects = DisplayLayout.normalize(
      frames: [
        CGRect(x: 0, y: 0, width: 1000, height: 1000),      // main
        CGRect(x: 0, y: 1000, width: 1000, height: 1000),   // stacked on top
      ],
      into: box, spacing: 0
    )
    #expect(rects[1].minY < rects[0].minY, "the upper screen must draw higher up")
  }

  @Test("A screen below the main one is drawn below it")
  func negativeOrigin() {
    let rects = DisplayLayout.normalize(
      frames: [
        CGRect(x: 0, y: 0, width: 1000, height: 1000),
        CGRect(x: 0, y: -1000, width: 1000, height: 1000),
      ],
      into: box, spacing: 0
    )
    #expect(rects[1].minY > rects[0].minY)
  }

  /// One scale for both axes. Scaling each axis independently would make every
  /// arrangement fill the box, and none of them look like the desk.
  @Test("Relative sizes are preserved")
  func aspectPreserved() {
    let rects = DisplayLayout.normalize(
      frames: [
        CGRect(x: 0, y: 0, width: 1000, height: 1000),
        CGRect(x: 1000, y: 0, width: 500, height: 1000),
      ],
      into: box, spacing: 0
    )
    #expect(abs(rects[0].width / rects[1].width - 2) < 0.001)
    #expect(abs(rects[0].height - rects[1].height) < 0.001)
  }

  @Test("Everything lands inside the box")
  func staysInsideTheBox() {
    let rects = DisplayLayout.normalize(
      frames: [
        CGRect(x: -1440, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 0, width: 3840, height: 2160),
        CGRect(x: 0, y: 2160, width: 1920, height: 1080),
      ],
      into: box
    )
    for rect in rects {
      #expect(rect.minX >= box.minX - 0.001)
      #expect(rect.minY >= box.minY - 0.001)
      #expect(rect.maxX <= box.maxX + 0.001)
      #expect(rect.maxY <= box.maxY + 0.001)
    }
  }

  /// Spacing is an inset, and an inset larger than the rectangle turns it
  /// inside out. On a five-monitor wall in a 120 pt strip that is not
  /// hypothetical.
  @Test("Spacing never inverts a small rectangle")
  func spacingCannotInvert() {
    let rects = DisplayLayout.normalize(
      frames: (0 ..< 12).map { CGRect(x: CGFloat($0) * 1000, y: 0, width: 1000, height: 1000) },
      into: box, spacing: 20
    )
    for rect in rects {
      #expect(rect.width > 0)
      #expect(rect.height > 0)
    }
  }

  @Test("A degenerate box produces empty rects rather than nonsense")
  func degenerateBox() {
    let rects = DisplayLayout.normalize(
      frames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
      into: CGRect(x: 0, y: 0, width: 0, height: 0)
    )
    #expect(rects == [.zero])
  }
}
