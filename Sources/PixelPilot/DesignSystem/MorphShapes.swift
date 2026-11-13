import SwiftUI

/// A rounded rectangle whose corner radius animates.
///
/// SwiftUI's `RoundedRectangle` does not interpolate its radius when the value
/// changes — it snaps. Making the radius the `animatableData` is what turns
/// "pill becomes squircle" into an actual morph rather than a jump.
struct MorphingRoundedRectangle: InsettableShape, Animatable {
  var cornerRadius: CGFloat
  /// Insettable so this can take `strokeBorder`, which draws inside the shape.
  /// Plain `stroke` straddles the edge, so half of every hairline would fall
  /// outside the card it is supposed to be outlining.
  private var inset: CGFloat = 0

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  init(cornerRadius: CGFloat) {
    self.cornerRadius = cornerRadius
  }

  func path(in rect: CGRect) -> Path {
    let bounds = rect.insetBy(dx: inset, dy: inset)
    // Continuous corners, not circular: this is the curvature Apple uses
    // everywhere, and mixing the two in one interface is immediately visible.
    return Path(
      roundedRect: bounds,
      cornerRadius: min(max(0, cornerRadius - inset), min(bounds.width, bounds.height) / 2),
      style: .continuous
    )
  }

  func inset(by amount: CGFloat) -> Self {
    var copy = self
    copy.inset += amount
    return copy
  }
}

/// The slider knob: a shape that changes width and corner radius together.
///
/// Modelled on the Material 3 Expressive slider handle, which is a tall pill at
/// rest and widens as you grab it. Both properties have to interpolate in step,
/// hence the `AnimatablePair` — animating them separately produces a visible
/// wobble where the radius outruns the width.
struct MorphingKnob: Shape, Animatable {
  var width: CGFloat
  var cornerRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(width, cornerRadius) }
    set {
      width = newValue.first
      cornerRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let knob = CGRect(
      x: rect.midX - width / 2,
      y: rect.minY,
      width: width,
      height: rect.height
    )
    return Path(
      roundedRect: knob,
      cornerRadius: min(cornerRadius, min(knob.width, knob.height) / 2),
      style: .continuous
    )
  }
}

/// Knob and track geometry for the native macOS Control Center Pill Slider.
///
/// Uses a consistent `26pt` Control Center pill track height (`13pt` capsule
/// radius) and a circular `20×20pt` thumb (`10pt` radius) that reveals on
/// hover and drag without Material 3 squircle morphing.
enum KnobGeometry {
  struct Metrics: Equatable {
    let width: CGFloat
    let cornerRadius: CGFloat
    let trackHeight: CGFloat
  }

  static let rest = Metrics(width: 20, cornerRadius: 10, trackHeight: 26)
  static let hovered = Metrics(width: 20, cornerRadius: 10, trackHeight: 26)
  static let dragging = Metrics(width: 20, cornerRadius: 10, trackHeight: 26)

  static func metrics(isDragging: Bool, isHovered: Bool) -> Metrics {
    if isDragging { return KnobGeometry.dragging }
    if isHovered { return KnobGeometry.hovered }
    return KnobGeometry.rest
  }
}
