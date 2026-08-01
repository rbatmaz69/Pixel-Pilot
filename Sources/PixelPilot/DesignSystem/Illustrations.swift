import SwiftUI

// The places nobody designs and everybody stares at.
//
// An empty state is not a rare corner: it is the first thing a new user sees,
// and it is where someone lands when something has gone wrong. Those are the
// two moments the interface has the most explaining to do and the least to
// show, and a line of grey text does none of it.
//
// Both illustrations follow `AmbientBackdrop`'s rules, because they are the
// same kind of thing — the only other views in this app that move on their own:
//
// - `phaseAnimator`, never `TimelineView`. A timeline re-runs its body on the
//   main actor every frame; phases hand off to the render server.
// - Scale and opacity only. A blur radius that animates is an offscreen pass
//   per frame, so the blur stays on static shapes under `.compositingGroup()`.
// - Under reduced motion the animator is *removed from the hierarchy*, not
//   given a zero duration. A repeating animation with no duration still
//   schedules a frame callback forever.

// MARK: - Illustrations

/// A monitor, breathing.
///
/// For "no display selected" — the app is not busy, it is waiting, and the
/// difference matters. A spinner would claim work is happening.
struct BreathingMonitor: View {
  /// Unset means the theme's, the same convention `PanelCard` follows.
  var accent: Color?
  var size: CGFloat = 76

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  private var tone: Color { accent ?? theme.tone }
  private var isStill: Bool { motion.isReduced || motion.ambientPeriod <= 0 }

  var body: some View {
    Group {
      if isStill {
        monitor
      } else {
        monitor.phaseAnimator([false, true]) { content, inhaled in
          content
            .scaleEffect(inhaled ? 1.04 : 0.98)
            .opacity(inhaled ? 1 : 0.82)
        } animation: { _ in
          // Slower than the ambient drift by a little. A screen that breathes
          // at conversational speed reads as impatient.
          .easeInOut(duration: motion.ambientPeriod * 0.45)
        }
      }
    }
    .compositingGroup()
    .accessibilityHidden(true)
  }

  private var monitor: some View {
    VStack(spacing: 0) {
      MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
        .fill(theme.wash(for: tone))
        .overlay {
          MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
            .strokeBorder(theme.rim(for: tone), lineWidth: 1.5)
        }
        .overlay {
          // The glow the panel would be putting out. Blurred once, on a static
          // shape, and carried by the group's transform from there.
          Ellipse()
            .fill(tone.opacity(0.35))
            .frame(width: size * 0.5, height: size * 0.28)
            .blur(radius: 14)
        }
        .frame(width: size, height: size * 0.62)

      // Stand and foot, at the widths that read as a monitor rather than as a
      // rectangle with a stick under it.
      Rectangle()
        .fill(theme.rim(for: tone))
        .frame(width: size * 0.12, height: size * 0.1)
      MorphingRoundedRectangle(cornerRadius: 2)
        .fill(theme.rim(for: tone))
        .frame(width: size * 0.36, height: 3)
    }
  }
}

/// Rings going out from a point, one after another.
///
/// For "nothing here yet" — this app finds things: displays on a bus, keys on a
/// keyboard, and presets it has been given. A radar says looking; an empty box
/// says broken.
struct SearchingRadar: View {
  var accent: Color?
  var size: CGFloat = 72

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  private var tone: Color { accent ?? theme.tone }
  private var isStill: Bool { motion.isReduced || motion.ambientPeriod <= 0 }
  private static let ringCount = 3

  var body: some View {
    ZStack {
      ForEach(0 ..< Self.ringCount, id: \.self) { index in
        ring(delayedBy: Double(index))
      }

      Circle()
        .fill(theme.fill(for: tone))
        .frame(width: 9, height: 9)
        .shadow(color: theme.glow(for: tone, active: true), radius: 5)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func ring(delayedBy index: Double) -> some View {
    let shape = Circle().strokeBorder(tone, lineWidth: 1.5).frame(width: size, height: size)

    if isStill {
      // Concentric and stationary: still legible as a radar, with nothing
      // running. Spacing them by index is what keeps them from stacking into
      // one thick circle.
      shape.scaleEffect(0.4 + index * 0.3).opacity(0.35)
    } else {
      // Three phases, not two. A two-phase animator plays the ripple in
      // reverse on the way back, which reads as the ring being sucked in; the
      // middle phase resets the scale while it is invisible. `AccentDot` makes
      // the same point at greater length.
      shape.phaseAnimator([0, 1, 2]) { content, phase in
        content
          .scaleEffect(phase == 1 ? 1 : 0.25)
          .opacity(phase == 0 ? 0.55 : 0)
      } animation: { phase in
        switch phase {
        case 1: .easeOut(duration: 1.6).delay(index * 0.45)
        case 2: .linear(duration: 0.01)
        default: .easeIn(duration: 0.2)
        }
      }
    }
  }
}

// MARK: - Empty state

/// An illustration, a heading, an explanation, and a way out.
///
/// Replaces `ContentUnavailableView`, which is correct and completely inert —
/// and which draws system chrome in an app where nothing else does, so it reads
/// as a page that belongs to a different program.
struct CharacterfulEmptyState<Illustration: View>: View {
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?
  var accent: Color?
  @ViewBuilder var illustration: Illustration

  var body: some View {
    VStack(spacing: Layout.normal) {
      illustration
        .padding(.bottom, Layout.tight)

      VStack(spacing: Layout.tight) {
        Text(title)
          .font(TypeScale.sheetTitle)
        Text(message)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 280)
      }

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(SoftButtonStyle(accent: accent, isProminent: true))
      }
    }
    .padding(Layout.section)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
