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

  @Test("Snapping docks gapless on the right and aligns top edges within threshold")
  func snapRightTopFlush() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let rawMoving = CGRect(x: 2100, y: 12, width: 1440, height: 900)

    let result = DisplayLayout.snap(moving: rawMoving, against: [main], threshold: 24)
    #expect(result.frame == CGRect(x: 1920, y: 0, width: 1440, height: 900))
    #expect(result.guides.contains(DisplayLayout.AlignmentGuide(axis: .horizontal, position: 0)))
  }

  @Test("Snapping prevents interior overlap when dragged onto an existing monitor")
  func snapPreventsOverlap() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let rawMoving = CGRect(x: -1380, y: 80, width: 1440, height: 900)

    let result = DisplayLayout.snap(moving: rawMoving, against: [main], threshold: 24)
    // Should dock cleanly on the left edge at x = -1440 with midY centered on main (540)
    #expect(abs(result.frame.maxX - main.minX) < 0.001)
    #expect(!result.frame.insetBy(dx: 0.5, dy: 0.5).intersects(main))
    #expect(result.guides.contains(DisplayLayout.AlignmentGuide(axis: .horizontal, position: 540)))
  }

  @Test("Snapping docks vertically above or below and aligns horizontal center")
  func snapAboveCenterAligned() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // Centered x is (1920 - 1280) / 2 = 320
    let rawMoving = CGRect(x: 332, y: -800, width: 1280, height: 720)

    let result = DisplayLayout.snap(moving: rawMoving, against: [main], threshold: 24)
    #expect(result.frame == CGRect(x: 320, y: -720, width: 1280, height: 720))
    #expect(result.guides.contains(DisplayLayout.AlignmentGuide(axis: .vertical, position: 960)))
  }

  @Test("Assigning a new primary display normalizes its origin to (0, 0)")
  func assignPrimaryNormalizesOrigins() {
    let entries = [
      DisplayLayout.ArrangementEntry(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
      DisplayLayout.ArrangementEntry(id: 2, frame: CGRect(x: 1920, y: 120, width: 2560, height: 1440)),
    ]

    let reassigned = DisplayLayout.assignPrimary(id: 2, in: entries)
    #expect(reassigned[0].frame.origin == CGPoint(x: -1920, y: -120))
    #expect(reassigned[1].frame.origin == CGPoint(x: 0, y: 0))
  }
}
