import PixelPilotCore
import SwiftUI

/// Where a mark sits on screen — the one answer, used by everything.
///
/// **This exists because there used to be two of them.** The crop marks were
/// drawn around the stored region held open to a minimum of 34 points, and the
/// repair pass exercised the same region held open to a minimum of 12 *device*
/// pixels — six points on a Retina panel. So a click mark was drawn nearly six
/// times larger than the area actually being worked, and the honest complaint
/// was that you could not tell whether the flashing had covered the pixel you
/// marked at all.
///
/// Now there is one rectangle. What is drawn is what is exercised, in the same
/// units, from the same function. A box dragged round a patch is worked at
/// exactly the size it was dragged; a single click is worked at the smallest
/// size that is still visible, and drawn at that size too.
enum MarkGeometry {
  /// The smallest a mark is ever drawn or exercised, in points.
  ///
  /// A stored click mark is a few device pixels — the right thing to *record*,
  /// and far too small to see, to click again, or to hand to Core Animation as
  /// its own layer. Everything downstream opens it to this.
  static let minimumSide: CGFloat = 34
  /// How far outside the region the crop marks sit, so they never cover it.
  static let gap: CGFloat = 6
  static let tick: CGFloat = 8

  /// The region itself: what flashes, and what the crop marks are drawn around.
  static func region(_ region: NormalisedRect, in size: CGSize) -> CGRect {
    let stored = region.denormalised(in: size)
    let width = max(stored.width, minimumSide)
    let height = max(stored.height, minimumSide)
    return CGRect(
      x: stored.midX - width / 2,
      y: stored.midY - height / 2,
      width: width,
      height: height
    )
  }

  /// Four corner ticks around `region`, outside it.
  ///
  /// A ring would cover the pixels immediately surrounding the suspect one, and
  /// those are exactly the ones it is being compared against — a speck only
  /// reads as wrong next to the ones that are right.
  static func brackets(around region: CGRect) -> Path {
    let rect = region.insetBy(dx: -gap, dy: -gap)
    // Never more than a third of a side, so the two ticks along an edge can
    // never meet however small or oddly shaped the mark is. Four ticks that
    // touch are a rectangle, which is the thing this is not.
    let length = min(tick, min(rect.width, rect.height) / 3)

    var path = Path()
    for corner in [
      (rect.minX, rect.minY, 1.0, 1.0),
      (rect.maxX, rect.minY, -1.0, 1.0),
      (rect.minX, rect.maxY, 1.0, -1.0),
      (rect.maxX, rect.maxY, -1.0, -1.0),
    ] {
      let (x, y, dx, dy) = corner
      path.move(to: CGPoint(x: x + dx * length, y: y))
      path.addLine(to: CGPoint(x: x, y: y))
      path.addLine(to: CGPoint(x: x, y: y + dy * length))
    }
    return path
  }

  /// The short stroke that says "dead" rather than "stuck".
  ///
  /// Outside the top-left corner rather than across it: a slash drawn over the
  /// tick turns a corner into a scribble, and the shape is the only thing
  /// telling the two apart — marks are never coloured, for the same reason
  /// nothing else on this overlay is.
  static func deadSlash(around region: CGRect) -> Path {
    let rect = region.insetBy(dx: -gap, dy: -gap)
    let length = min(tick, min(rect.width, rect.height) / 3)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX - gap - length, y: rect.minY - gap))
    path.addLine(to: CGPoint(x: rect.minX - gap, y: rect.minY - gap - length))
    return path
  }
}

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
    // The same rectangle the repair pass will flash — see `MarkGeometry`, which
    // exists because these were once two different numbers.
    let region = MarkGeometry.region(defect.region, in: size)
    let stroke = StrokeStyle(lineWidth: 1, lineCap: .butt)

    context.stroke(MarkGeometry.brackets(around: region), with: .color(colour), style: stroke)

    guard defect.kind == .dead else { return }
    context.stroke(MarkGeometry.deadSlash(around: region), with: .color(colour), style: stroke)
  }
}
