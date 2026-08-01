import SwiftUI

/// A slowly drifting wash of the display's accent, for the back of a card.
///
/// The one thing in this app that moves on its own — so how it moves matters
/// more here than anywhere else.
///
/// `.phaseAnimator` rather than `TimelineView`: a timeline re-runs its body on
/// the main actor every frame, which for a decorative glow is the exact cost
/// this app exists to refuse. Phases animate offset, scale and opacity, and
/// Core Animation interpolates those on the render server — so a full drift
/// cycle costs two main-actor passes rather than several hundred.
///
/// The blur is applied to the static shapes and never animated. An animating
/// blur radius is an offscreen pass per frame; `.compositingGroup()` is what
/// keeps the blurred result cached while only the transform moves.
///
/// Nothing here needs tearing down. There is no timer and no task — closing the
/// panel destroys the hierarchy, and the animation goes with it.
struct AmbientBackdrop: View {
  let accent: Color
  /// How strongly to draw it. `nil` takes the theme's answer, which is what
  /// every call site wants — the three of them pass a number only when the
  /// surface they are on needs less than the style asks for.
  var intensity: Double?
  /// False parks the drift without removing the view. Callers pass window
  /// activity here, so a window sitting behind another stops moving instead of
  /// glowing away at nobody.
  var isVisible: Bool = true

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  /// The style's strength scaled by whatever the call site asked for, so a
  /// surface that wants a quieter wash stays quieter under every style — and
  /// so a style with no wash at all silences every one of them.
  private var strength: Double { theme.ambientIntensity * (intensity ?? 1) }

  private enum Drift: CaseIterable {
    case ebb, flow

    var offset: CGSize {
      self == .ebb ? CGSize(width: -14, height: -9) : CGSize(width: 16, height: 11)
    }

    var scale: CGFloat { self == .ebb ? 0.92 : 1.10 }
    var opacity: Double { self == .ebb ? 0.75 : 1.0 }
  }

  private var isStill: Bool { motion.isReduced || motion.ambientPeriod <= 0 || !isVisible }

  var body: some View {
    // A style with no wash removes it rather than fading it out. `.opacity(0)`
    // would leave the phase animator scheduling a frame callback forever for
    // something nobody can see — the same argument the reduced-motion branch
    // below makes, and the same reason this type has no timer in it.
    if strength <= 0 {
      EmptyView()
    } else {
      blobStack
    }
  }

  private var blobStack: some View {
    Group {
      if isStill {
        // A branch, not a zero duration. A repeating animation with no duration
        // still schedules a frame callback forever, which is the opposite of
        // what someone asking for reduced motion wants.
        blobs
      } else {
        blobs.phaseAnimator(Drift.allCases) { content, drift in
          content
            .offset(drift.offset)
            .scaleEffect(drift.scale)
            .opacity(drift.opacity)
        } animation: { _ in
          .easeInOut(duration: motion.ambientPeriod)
        }
      }
    }
    .compositingGroup()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The strength is carried by the fills rather than by an opacity on the
  /// group. At full strength the two are identical, and above it only the fills
  /// can go — an opacity has nowhere above 1 to put a style that wants *more*
  /// wash than the default rather than less.
  private var blobs: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(min(0.30 * strength, 1)))
        .frame(width: 170, height: 170)
        .blur(radius: 42)
        .offset(x: -52, y: -26)

      Circle()
        .fill(theme.lifted(accent).opacity(min(0.22 * strength, 1)))
        .frame(width: 130, height: 130)
        .blur(radius: 36)
        .offset(x: 62, y: 30)
    }
  }
}
