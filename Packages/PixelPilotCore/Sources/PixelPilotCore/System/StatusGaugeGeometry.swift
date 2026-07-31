import CoreGraphics

/// The menu bar icon's fill level, as rectangles.
///
/// Pure geometry, in the tested package, because the drawing around it cannot
/// be: a menu bar image is a *template*, meaning macOS throws away every colour
/// in it and keeps only the alpha. So the level cannot be a lighter grey — it
/// has to be a shape that is either there or not, and getting a shape wrong at
/// the edges of its range is how an icon ends up drawing a sliver at zero or
/// spilling past its own outline at one.
public enum StatusGaugeGeometry {
  /// The filled part of a gauge, measured from the bottom.
  ///
  /// - Parameters:
  ///   - level: 0...1. Values outside are clamped rather than rejected —
  ///     callers get this from hardware, and a monitor reporting 1.02 should
  ///     produce a full icon, not a crash.
  ///   - bounds: The icon's box.
  ///   - inset: Gap between the outline and the fill, on every side.
  public static func fillRect(for level: Double, in bounds: CGRect, inset: CGFloat) -> CGRect {
    let well = bounds.insetBy(dx: inset, dy: inset)
    guard well.width > 0, well.height > 0 else { return .zero }

    let clamped = min(1, max(0, level))
    let height = well.height * clamped
    // An empty rect rather than a zero-height one at the bottom edge: a rect
    // with no area still draws a hairline in some contexts, and a gauge at zero
    // that shows a line is indistinguishable from one stuck at 2 %.
    guard height > 0 else { return .zero }

    return CGRect(x: well.minX, y: well.minY, width: well.width, height: height)
  }
}
