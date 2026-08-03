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
  /// What a drag on the track means, or nil for an indicator with nothing to
  /// drag — a mute state, or a route this app cannot move.
  var adjust: ((Double) -> Void)?
  /// The verified write, once, when the drag ends.
  var commit: (() -> Void)?

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  /// Drives the arrival. Flipped in `onAppear`, which fires once per panel —
  /// `OSDController` swaps `rootView` rather than rebuilding the hosting view,
  /// so holding a key down updates the value without replaying the entrance.
  @State private var hasArrived = false
  /// Bumped when the level lands on an end, to nudge the whole card.
  @State private var endStop = 0
  /// Where a drag has put the level, until the next value arrives from outside.
  ///
  /// The HUD is handed a value rather than observing one, so without this the
  /// handle would spring back to whatever the last key press said the moment it
  /// was let go.
  @State private var scrubbed: Double?

  private var isMuted: Bool { kind == .muted }

  /// The level being shown: what was dragged if anything was, otherwise what
  /// was handed in.
  private var level: Double { scrubbed ?? value }

  /// Whether the track can be grabbed at all.
  private var isAdjustable: Bool { adjust != nil && !isMuted }

  var body: some View {
    VStack(spacing: Layout.snug) {
      ZStack {
        bloom
        Image(systemName: kind.symbol(for: level))
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.fill(for: accent)))
          // The symbol swaps as the level crosses a threshold; a replace
          // transition makes that read as one icon changing rather than two
          // icons flickering. The bounce is what makes crossing a threshold
          // feel like an event rather than a redraw.
          .contentTransition(.symbolEffect(.replace.downUp))
          .symbolEffect(.bounce, value: kind.symbol(for: level))
      }
      .frame(height: 44)

      if !isMuted {
        Text("\(Int((level * 100).rounded()))%")
          .font(TypeScale.heroReadout)
          .foregroundStyle(theme.ink(for: accent))
          .contentTransition(.numericText(value: level))
          .animation(motion.effectFast, value: level)
      }

      // A slider from the first frame, not one that appears once the pointer
      // arrives. Revealing it on hover was the first attempt, and it made the
      // whole feature hostage to hover detection — in a panel belonging to an
      // app that is never active, which is exactly where hover detection is
      // hardest to get right. It also hid the affordance: a control you can
      // only discover by pointing at something that looks like a progress bar
      // is a control most people never find.
      //
      // A fixed height, so the plate is never resized under the pointer. The
      // window is sized once, when the HUD is shown.
      ZStack {
        if isAdjustable {
          ExpressiveSlider(
            // An explicit closure rather than passing `scrub` by reference:
            // handing a main-actor method straight to `Binding` crashes the
            // 6.3.3 compiler in IRGen, on the thunk it builds to strip the
            // isolation off.
            value: Binding(get: { level }, set: { scrub($0) }),
            accent: accent,
            // No marks. The HUD is a glance, and a quarter that tugs is a
            // detail for a control you are settling into rather than one you
            // reached for on the way past.
            detents: [],
            onCommit: { _ in commit?() }
          )
        } else {
          track
        }
      }
      .frame(height: KnobGeometry.dragging.trackHeight + 12)

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
    .onChange(of: level) { _, updated in
      if updated <= 0.001 || updated >= 0.999 { endStop += 1 }
    }
    // A key press is the outside world speaking, and it wins: whatever a drag
    // left behind is dropped rather than left to argue with the new figure.
    .onChange(of: value) { _, _ in scrubbed = nil }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.accessibilityLabel)
    .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    .accessibilityAdjustableAction { direction in
      guard isAdjustable else { return }
      let step = 1.0 / 16.0
      scrub(min(1, max(0, level + (direction == .increment ? step : -step))))
      commit?()
    }
  }

  /// Where a drag has put the level. Cheap work only — the write that has to be
  /// verified happens in `commit`, once, when the drag ends.
  private func scrub(_ updated: Double) {
    scrubbed = updated
    adjust?(updated)
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
      let filled = max(8, width * min(1, max(0, level)))

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
