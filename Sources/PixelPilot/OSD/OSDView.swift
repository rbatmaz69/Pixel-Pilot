import PixelPilotCore
import SwiftUI

/// What the heads-up display is showing.
enum OSDKind: Equatable {
  case brightness
  case contrast
  /// The white point. The only kind whose figure is not a percentage — `value`
  /// is still a fraction of `ColorTemperature.range`, because that is what a
  /// track is, and the readout converts it back.
  case warmth
  case volume
  case muted
  /// The key was pressed, understood, and there is nothing to move.
  ///
  /// Worth a HUD of its own rather than silence. "This app did not react" and
  /// "this app reacted and the hardware cannot do it" look identical when both
  /// produce nothing, and the difference is the whole question somebody has
  /// when their volume keys stop working on a new monitor. The same reasoning
  /// as `DisplayViewModel.volumeUnavailableReason`, which spells the case out
  /// on the display's settings page instead of just omitting the slider.
  ///
  /// It carries what it is about, because it stopped being only about volume
  /// the moment a contrast key could be pressed on a panel with no contrast.
  case unavailable(Unavailable)
  /// A preset was applied. The only kind with no level at all.
  ///
  /// It exists for the shortcuts that step through presets: pressing "next"
  /// twice with nothing on screen is a change you have to go and verify, which
  /// is the opposite of what a shortcut is for.
  case preset(name: String, symbol: String)

  enum Unavailable: Equatable {
    case volume
    case contrast
  }

  /// Icon that reflects the level, the way the system OSD does — a speaker with
  /// no waves at zero reads as "off" without needing to parse a number.
  func symbol(for value: Double) -> String {
    switch self {
    case .brightness:
      value < 0.34 ? "sun.min.fill" : (value < 0.67 ? "sun.max" : "sun.max.fill")
    case .contrast:
      "circle.lefthalf.filled"
    case .warmth:
      // Warm end, neutral, cool end. The same three-way reading the slider's
      // labels give, so the glyph and the track agree about which way is which.
      value < 0.4 ? "thermometer.sun.fill" : (value < 0.72 ? "thermometer.medium" : "snowflake")
    case .volume:
      if value <= 0.001 { "speaker.fill" }
      else if value < 0.34 { "speaker.wave.1.fill" }
      else if value < 0.67 { "speaker.wave.2.fill" }
      else { "speaker.wave.3.fill" }
    case .muted:
      "speaker.slash.fill"
    case let .unavailable(what):
      // Not the slashed speaker, which is already muted's. Muted is a state you
      // put the thing into and can take it out of again; this is a control that
      // does not exist. Drawing them the same would answer "did I just mute
      // it?" with a shrug.
      switch what {
      case .volume: "speaker.badge.exclamationmark.fill"
      case .contrast: "circle.badge.exclamationmark.fill"
      }
    case let .preset(_, symbol):
      symbol
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .brightness: "Helligkeit"
    case .contrast: "Kontrast"
    case .warmth: "Farbwärme"
    case .volume: "Lautstärke"
    case .muted: "Stumm"
    case .unavailable(.volume): "Lautstärke nicht verfügbar"
    case .unavailable(.contrast): "Kontrast nicht verfügbar"
    case .preset: "Preset aktiviert"
    }
  }

  /// Whether there is a figure and a track at all.
  ///
  /// False for the three that report rather than set: a mute state, a control
  /// that is not there, and a preset that has already been applied.
  var hasLevel: Bool {
    switch self {
    case .brightness, .contrast, .warmth, .volume: true
    case .muted, .unavailable, .preset: false
    }
  }

  /// The figure over the track, in whatever unit this kind is in.
  func readout(for value: Double) -> String {
    switch self {
    case .warmth:
      let range = ColorTemperature.range
      let kelvin = range.lowerBound + value * (range.upperBound - range.lowerBound)
      // Neutral is a state, not a temperature — at neutral there is no table of
      // ours on the display at all, and "6500 K" would report a setting where
      // the honest answer is that there isn't one.
      return abs(kelvin - ColorTemperature.neutralKelvin) < 25
        ? "Neutral" : "\(Int((kelvin / 50).rounded() * 50)) K"
    case let .preset(name, _):
      return name
    default:
      return "\(Int((value * 100).rounded()))%"
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
  /// Why there is nothing to move, for `.unavailable`. One line, and the short
  /// form of `DisplayViewModel.volumeUnavailableReason` — a plate 210 points
  /// wide is not the place for the three-sentence version the window carries.
  var detail: String?
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
  private var isUnavailable: Bool { if case .unavailable = kind { true } else { false } }
  private var isPreset: Bool { if case .preset = kind { true } else { false } }

  /// The level being shown: what was dragged if anything was, otherwise what
  /// was handed in.
  private var level: Double { scrubbed ?? value }

  /// Whether the track can be grabbed at all.
  private var isAdjustable: Bool { adjust != nil && kind.hasLevel }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      // Top header row: icon badge + title & AccentDot display subtitle + tabular readout
      HStack(spacing: Layout.snug) {
        ZStack {
          RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
            .fill(isMuted || isUnavailable ? AnyShapeStyle(theme.recessedWell) : AnyShapeStyle(theme.wash(for: accent)))
            .overlay {
              RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
                .strokeBorder(
                  isMuted || isUnavailable ? theme.groupBorder : theme.rim(for: accent).opacity(0.55),
                  lineWidth: 1
                )
            }
            .frame(width: 28, height: 28)

          Image(systemName: kind.symbol(for: level))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(glyphStyle)
            .contentTransition(.symbolEffect(.replace.downUp))
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(kind.accessibilityLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          HStack(spacing: 5) {
            AccentDot(accent: accent, isReady: !isUnavailable, size: 6)
            Text(displayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 6)

        if kind.hasLevel {
          Text(kind.readout(for: level))
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(theme.ink(for: accent))
            .contentTransition(.numericText(value: level))
            .animation(motion.effectFast, value: level)
        } else if isPreset {
          Text(kind.readout(for: level))
            .font(.callout.weight(.semibold))
            .foregroundStyle(theme.ink(for: accent))
            .lineLimit(1)
        } else if isMuted {
          Text("Muted")
            .font(TypeScale.detail.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }

      // Interactive Control Center Pill Slider row
      if !isPreset {
        ZStack {
          if isAdjustable {
            ExpressiveSlider(
              value: Binding(get: { level }, set: { scrub($0) }),
              accent: accent,
              icon: kind.symbol(for: level),
              trackStyle: kind == .warmth ? AnyShapeStyle(KelvinTrack.gradient) : nil,
              detents: SliderDetents.quarters,
              onCommit: { _ in commit?() }
            )
          } else {
            track
          }
        }
        .frame(height: KnobGeometry.rest.trackHeight)
      }

      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 190, alignment: .leading)
          .padding(.top, 4)
      }
    }
    .padding(.horizontal, Layout.normal)
    .padding(.vertical, 12)
    .frame(width: 296)
    .heroSurface()
    .scaleEffect(hasArrived ? 1 : 0.96)
    .opacity(hasArrived ? 1 : 0)
    .animation(motion.expressive, value: hasArrived)
    .modifier(EndStopNudge(trigger: endStop, isReduced: motion.isReduced, settle: motion.expressive))
    .onAppear { hasArrived = true }
    .onChange(of: level) { _, updated in
      if updated <= 0.001 || updated >= 0.999 { endStop += 1 }
    }
    .onChange(of: value) { _, _ in scrubbed = nil }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.accessibilityLabel)
    .accessibilityValue(kind.readout(for: level))
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

  /// The glyph's colour. Accent when there is a level to report, and out of the
  /// accent entirely when there is not — the app's colour is what it uses to
  /// say "this is a thing you set", and the unavailable HUD is the one case
  /// where it is not.
  private var glyphStyle: AnyShapeStyle {
    // A preset keeps the accent: it is a thing that was set, which is exactly
    // what the colour is for. Only the two that report a dead end lose it.
    isMuted || isUnavailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.fill(for: accent))
  }

  private var track: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let filled = max(8, width * min(1, max(0, level)))

      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.quaternary)

        // Nothing on top of the empty capsule when there is no level. A fill of
        // any width would be a reading, and the point of this HUD is that there
        // is nothing to read.
        if !isUnavailable {
          Capsule(style: .continuous)
            .fill(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(theme.fill(for: accent)))
            .frame(width: filled)
            .shadow(color: theme.glow(for: accent, active: !isMuted), radius: 6, y: 1)
            // A spatial spring: the fill is a thing moving, so a little
            // overshoot is what makes repeated key presses feel responsive
            // instead of mechanical.
            .animation(motion.spatialFast, value: filled)
        }
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

  func body(content: Content) -> some View {
    content
  }
}
