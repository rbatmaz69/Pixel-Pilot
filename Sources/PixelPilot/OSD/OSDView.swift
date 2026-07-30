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

  private var isMuted: Bool { kind == .muted }

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: kind.symbol(for: value))
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
        .frame(height: 40)
        // The symbol swaps as the level crosses a threshold; a replace
        // transition makes that read as one icon changing rather than two
        // icons flickering.
        .contentTransition(.symbolEffect(.replace.downUp))

      track

      Text(displayName)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 20)
    .frame(width: 200)
    .glassEffect(.regular, in: .rect(cornerRadius: 26))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.accessibilityLabel)
    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
  }

  private var track: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let filled = max(6, width * min(1, max(0, value)))

      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.quaternary)

        Capsule(style: .continuous)
          .fill(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accent.gradient))
          .frame(width: filled)
          // A spatial spring: the fill is a thing moving, so a little overshoot
          // is what makes repeated key presses feel responsive instead of
          // mechanical.
          .animation(motion.spatialFast, value: filled)
      }
    }
    .frame(height: 6)
  }
}
