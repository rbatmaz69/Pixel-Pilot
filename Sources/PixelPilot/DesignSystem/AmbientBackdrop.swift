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
  var intensity: Double = 1.0
  /// False parks the drift without removing the view. Callers pass window
  /// activity here, so a window sitting behind another stops moving instead of
  /// glowing away at nobody.
  var isVisible: Bool = true

  @Environment(\.motion) private var motion

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
    .opacity(intensity)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var blobs: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.30))
        .frame(width: 170, height: 170)
        .blur(radius: 42)
        .offset(x: -52, y: -26)

      Circle()
        .fill(accent.accentLift.opacity(0.22))
        .frame(width: 130, height: 130)
        .blur(radius: 36)
        .offset(x: 62, y: 30)
    }
  }
}
