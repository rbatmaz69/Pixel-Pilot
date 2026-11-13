import SwiftUI

/// The number on the screen.
///
/// Big enough to read across a desk, in the display's own accent so the map in
/// the sidebar and the monitor in front of you say the same thing twice — the
/// colour is the part that survives being glanced at.
struct IdentifyOverlay: View {
  let number: Int
  let name: String
  let accent: Color

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var hasArrived = false

  var body: some View {
    VStack(spacing: Layout.tight) {
      Text("\(number)")
        .font(TypeScale.identityNumeral)
        .foregroundStyle(theme.fill(for: accent))
        .shadow(color: theme.glow(for: accent, active: true), radius: 24)

      HStack(spacing: Layout.tight) {
        AccentDot(accent: accent, isReady: true, size: 10)
        Text(name)
          .font(TypeScale.sheetTitle)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, Layout.section * 2)
    .padding(.vertical, Layout.section)
    // The plate is the app's colour and the numeral is the display's. Tinting
    // the plate with the accent too would put the same hue at two strengths on
    // top of each other, and the numeral is the part meant to be read from
    // across a desk.
    .heroSurface()
    .scaleEffect(hasArrived ? 1 : 0.96)
    .opacity(hasArrived ? 1 : 0)
    .animation(motion.expressive, value: hasArrived)
    .onAppear { hasArrived = true }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Display \(number), \(name)")
  }
}
