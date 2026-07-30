import SwiftUI

/// A rounded rectangle whose corner radius animates.
///
/// SwiftUI's `RoundedRectangle` does not interpolate its radius when the value
/// changes — it snaps. Making the radius the `animatableData` is what turns
/// "pill becomes squircle" into an actual morph rather than a jump.
struct MorphingRoundedRectangle: Shape, Animatable {
  var cornerRadius: CGFloat

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  func path(in rect: CGRect) -> Path {
    // Continuous corners, not circular: this is the curvature Apple uses
    // everywhere, and mixing the two in one interface is immediately visible.
    Path(roundedRect: rect, cornerRadius: min(cornerRadius, min(rect.width, rect.height) / 2), style: .continuous)
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

/// Knob geometry for each interaction state.
///
/// Kept as data rather than scattered literals so the whole morph can be read —
/// and adjusted — in one place.
enum KnobGeometry {
  struct Metrics: Equatable {
    let width: CGFloat
    let cornerRadius: CGFloat
    let trackHeight: CGFloat
  }

  static let rest = Metrics(width: 6, cornerRadius: 3, trackHeight: 6)
  static let hovered = Metrics(width: 9, cornerRadius: 4.5, trackHeight: 11)
  /// Widening on grab is the tactile cue: the control acknowledges the press
  /// before the value has moved at all. Three times the resting width, because
  /// a difference you have to look for is not a cue.
  static let dragging = Metrics(width: 18, cornerRadius: 7, trackHeight: 14)

  static func metrics(isDragging: Bool, isHovered: Bool) -> Metrics {
    if isDragging { return KnobGeometry.dragging }
    if isHovered { return KnobGeometry.hovered }
    return KnobGeometry.rest
  }
}
