import AppKit
import PixelPilotCore

/// Draws the menu bar icon at a given brightness.
///
/// The constraint that shapes all of this: a menu bar image is a **template**.
/// macOS discards every colour and keeps only the alpha, then tints the result
/// for light, dark and tinted menu bars. So the level cannot be a lighter grey
/// — there is no such thing here. It has to be built from shapes that are
/// either present or absent: an outline, and a filled block inside it whose
/// height is the value.
///
/// That restriction is why this reads as a gauge rather than as a progress bar.
/// It is also why the geometry is tested elsewhere and only the drawing lives
/// here.
@MainActor
enum StatusIconRenderer {
  private static let size = CGSize(width: 18, height: 18)
  private static let outlineRadius: CGFloat = 4
  private static let outlineWidth: CGFloat = 1.25
  /// Between the outline and the fill. Without a gap the two merge into one
  /// solid block at high values and the outline stops reading as a container.
  private static let fillInset: CGFloat = 3.25

  /// The icon showing `level`, or the plain glyph when there is nothing to show
  /// — no displays, or none that answer.
  static func image(level: Double?) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
      let outline = rect.insetBy(dx: outlineWidth / 2 + 1, dy: outlineWidth / 2 + 1)
      let path = NSBezierPath(roundedRect: outline, xRadius: outlineRadius, yRadius: outlineRadius)
      path.lineWidth = outlineWidth
      NSColor.black.setStroke()
      path.stroke()

      if let level {
        let fill = StatusGaugeGeometry.fillRect(for: level, in: outline, inset: fillInset)
        guard !fill.isEmpty else { return true }
        // Rounded only where it will not fight the outline: a fully rounded
        // fill at 100 % leaves four visible gaps in the corners.
        let radius = min(1.5, fill.height / 2)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
