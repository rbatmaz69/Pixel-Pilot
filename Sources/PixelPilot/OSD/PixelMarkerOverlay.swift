import PixelPilotCore
import SwiftUI

/// The marks, drawn over the pattern they were found on.
///
/// Every rule here is the answer to an obvious failure, so they are worth
/// stating rather than being read off the drawing code:
///
/// **Crop marks, not a box.** Four corner ticks sitting *outside* the region. A
/// ring around a suspect pixel covers the pixels immediately around it, and
/// those are exactly the ones it is being compared against — a speck only reads
/// as wrong next to the ones that are right.
///
/// **Never filled.** Not once, not at low opacity. The pixel being reported on
/// has to stay visible while it is reported on, or the mark has replaced the
/// evidence with a claim about it.
///
/// **Inked against the pattern, not the theme.** Black on white, white on
/// black, and nothing else — the same reason `DisplayHealthController` refuses
/// the app's accent colour on this overlay. A red marker on a screen being
/// judged for colour is one more saturated thing to explain.
///
/// **Kind by shape, not by colour**, for the same reason: a dead mark gets a
/// slash through its top-left tick. Two colours of marker would be two more
/// colours on the screen.
struct PixelMarkerOverlay: View {
  let defects: [PixelDefect]
  let draft: CGRect?
  let ink: Ink

  /// Far enough outside the mark to leave its surroundings clear, close enough
  /// that four ticks still read as one thing.
  private static let gap: CGFloat = 6
  private static let tick: CGFloat = 8
  /// What the four ticks are drawn around, however small the mark itself is.
  ///
  /// A stored mark is a handful of device pixels. Drawn at its own size, the
  /// four ticks meet in the middle and become a closed box sitting on top of
  /// the very pixel being inspected — which is the one thing this file says it
  /// does not do. So the *drawn* frame has a floor even though the stored one
  /// does not: store tight, draw generous.
  private static let minimumDrawnSide: CGFloat = 34

  var body: some View {
    Canvas { context, size in
      for defect in defects {
        draw(defect, in: &context, size: size)
      }
      if let draft {
        // Dashed, so an in-progress region never looks like one that has been
        // recorded.
        context.stroke(
          Path(draft),
          with: .color(colour.opacity(0.8)),
          style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
      }
    }
    // Hit-testing is `PixelDefects.hitTest` against the normalised point, not
    // SwiftUI's: this sits over the whole screen, and a canvas that took the
    // pointer would be a canvas nobody could mark underneath.
    .allowsHitTesting(false)
  }

  private var colour: Color {
    switch ink {
    case .dark: .black
    case .light: .white
    }
  }

  private func draw(_ defect: PixelDefect, in context: inout GraphicsContext, size: CGSize) {
    let rect = frame(for: defect, in: size)
    let stroke = StrokeStyle(lineWidth: 1, lineCap: .butt)
    // Never more than a third of a side, so the two ticks along an edge can
    // never meet however small or oddly shaped the mark is. Four ticks that
    // touch are a rectangle, and a rectangle round a suspect pixel hides the
    // pixels it is being compared against.
    let tick = min(Self.tick, min(rect.width, rect.height) / 3)

    var path = Path()
    // Top left, top right, bottom left, bottom right — each an L of two
    // strokes, so the corner reads as a corner rather than as two dashes.
    for corner in corners(of: rect) {
      path.move(to: CGPoint(x: corner.x + corner.dx * tick, y: corner.y))
      path.addLine(to: CGPoint(x: corner.x, y: corner.y))
      path.addLine(to: CGPoint(x: corner.x, y: corner.y + corner.dy * tick))
    }
    context.stroke(path, with: .color(colour), style: stroke)

    guard defect.kind == .dead else { return }
    // Outside the top-left corner rather than across it: a slash drawn over the
    // tick turns a corner into a scribble, and the shape is the only thing
    // telling stuck from dead — marks are never coloured, for the same reason
    // nothing else on this overlay is.
    var slash = Path()
    slash.move(to: CGPoint(x: rect.minX - Self.gap - tick, y: rect.minY - Self.gap))
    slash.addLine(to: CGPoint(x: rect.minX - Self.gap, y: rect.minY - Self.gap - tick))
    context.stroke(slash, with: .color(colour), style: stroke)
  }

  /// Where the ticks go: the mark, held open to a legible minimum, plus the gap.
  private func frame(for defect: PixelDefect, in size: CGSize) -> CGRect {
    let stored = defect.region.denormalised(in: size)
    let width = max(stored.width, Self.minimumDrawnSide)
    let height = max(stored.height, Self.minimumDrawnSide)
    return CGRect(
      x: stored.midX - width / 2,
      y: stored.midY - height / 2,
      width: width,
      height: height
    )
    .insetBy(dx: -Self.gap, dy: -Self.gap)
  }

  private func corners(of rect: CGRect) -> [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] {
    [
      (rect.minX, rect.minY, 1, 1),
      (rect.maxX, rect.minY, -1, 1),
      (rect.minX, rect.maxY, 1, -1),
      (rect.maxX, rect.maxY, -1, -1),
    ]
  }
}
