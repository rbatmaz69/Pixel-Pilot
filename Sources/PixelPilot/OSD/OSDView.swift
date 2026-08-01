import SwiftUI

/// What the heads-up display is showing.
enum OSDKind: Equatable {
  case brightness
  case volume
  case muted

  /// Icon that reflects the level, the way the system OSD does — a speaker with
  /// no waves at zero reads as "off" without needing to parse a number.
  func symbol(for value: Double) -> String {
    switch self {
    case .brightness:
      value < 0.34 ? "sun.min.fill" : (value < 0.67 ? "sun.max" : "sun.max.fill")
    case .volume:
      if value <= 0.001 { "speaker.fill" }
      else if value < 0.34 { "speaker.wave.1.fill" }
      else if value < 0.67 { "speaker.wave.2.fill" }
      else { "speaker.wave.3.fill" }
    case .muted:
      "speaker.slash.fill"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .brightness: "Brightness"
    case .volume: "Volume"
    case .muted: "Muted"
    }
  }
}

/// The heads-up display shown when a brightness or volume key is pressed.
///
/// This is drawn rather than delegated to the system because macOS 26 reworked
/// the private OSD interface and third-party values no longer render there —
/// established apps show an empty or frozen indicator on Tahoe. Owning it also
/// means the app's motion language reaches the surface people see most often.
struct OSDView: View {
  let kind: OSDKind
  let value: Double
  let accent: Color
  let displayName: String

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  /// Drives the arrival. Flipped in `onAppear`, which fires once per panel —
  /// `OSDController` swaps `rootView` rather than rebuilding the hosting view,
  /// so holding a key down updates the value without replaying the entrance.
  @State private var hasArrived = false
  /// Bumped when the level lands on an end, to nudge the whole card.
  @State private var endStop = 0

  private var isMuted: Bool { kind == .muted }

  var body: some View {
    VStack(spacing: Layout.snug) {
      ZStack {
        bloom
        Image(systemName: kind.symbol(for: value))
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.fill(for: accent)))
          // The symbol swaps as the level crosses a threshold; a replace
          // transition makes that read as one icon changing rather than two
          // icons flickering. The bounce is what makes crossing a threshold
          // feel like an event rather than a redraw.
          .contentTransition(.symbolEffect(.replace.downUp))
          .symbolEffect(.bounce, value: kind.symbol(for: value))
      }
      .frame(height: 44)

      if !isMuted {
        Text("\(Int((value * 100).rounded()))%")
          .font(TypeScale.heroReadout)
          .foregroundStyle(theme.ink(for: accent))
          .contentTransition(.numericText(value: value))
          .animation(motion.effectFast, value: value)
      }

      track

      Text(displayName)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, Layout.loose)
    .padding(.vertical, Layout.loose)
    .frame(width: 210)
    .heroSurface()
    // Arrival: a spring in from slightly small and slightly soft. The blur is
    // on the finished glass rather than on anything being animated per frame.
    .scaleEffect(hasArrived ? 1 : 0.90)
    .opacity(hasArrived ? 1 : 0)
    .blur(radius: hasArrived ? 0 : 5)
    .animation(motion.expressive, value: hasArrived)
    .modifier(EndStopNudge(trigger: endStop, isReduced: motion.isReduced, settle: motion.expressive))
    .onAppear { hasArrived = true }
    .onChange(of: value) { _, updated in
      if updated <= 0.001 || updated >= 0.999 { endStop += 1 }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.accessibilityLabel)
    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
  }

  /// A soft halo behind the glyph, blooming once as the HUD arrives.
  ///
  /// One-shot rather than a loop: this thing is on screen for 1.4 seconds, and
  /// an ambient cycle slow enough to be calm would never finish.
  private var bloom: some View {
    Circle()
      .fill(RadialGradient(
        colors: [accent.opacity(isMuted ? 0 : 0.5), accent.opacity(0)],
        center: .center,
        startRadius: 1,
        endRadius: 46
      ))
      .frame(width: 96, height: 96)
      .scaleEffect(hasArrived ? 1 : 0.55)
      .opacity(hasArrived ? 1 : 0)
      .animation(motion.expressive, value: hasArrived)
  }

  private var track: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let filled = max(8, width * min(1, max(0, value)))

      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.quaternary)

        Capsule(style: .continuous)
          .fill(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.fill(for: accent)))
          .frame(width: filled)
          .shadow(color: theme.glow(for: accent, active: !isMuted), radius: 6, y: 1)
          // A spatial spring: the fill is a thing moving, so a little overshoot
          // is what makes repeated key presses feel responsive instead of
          // mechanical.
          .animation(motion.spatialFast, value: filled)
      }
    }
    .frame(height: 8)
  }
}

/// A short squash of the whole HUD when the level lands on an end.
///
/// The point is to make hitting zero or full felt rather than read. Three
/// phases so the card is guaranteed to come to rest at its own size, whichever
/// phase the animator settles on.
private struct EndStopNudge: ViewModifier {
  let trigger: Int
  let isReduced: Bool
  let settle: Animation

  @ViewBuilder
  func body(content: Content) -> some View {
    if isReduced {
      content
    } else {
      content.phaseAnimator([0, 1, 2], trigger: trigger) { view, phase in
        view.scaleEffect(phase == 1 ? 1.035 : 1)
      } animation: { phase in
        phase == 1 ? .spring(duration: 0.14, bounce: 0.5) : settle
      }
    }
  }
}
