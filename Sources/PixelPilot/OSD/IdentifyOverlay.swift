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
  @State private var hasArrived = false

  var body: some View {
    VStack(spacing: Layout.tight) {
      Text("\(number)")
        .font(TypeScale.identityNumeral)
        .foregroundStyle(accent.accentFill)
        .shadow(color: accent.accentGlow(true), radius: 24)

      Text(name)
        .font(TypeScale.sheetTitle)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, Layout.section * 2)
    .padding(.vertical, Layout.section)
    .glassEffect(.regular.tint(accent.accentWash), in: .rect(cornerRadius: Layout.radiusHero))
    // The HUD's arrival, in one line each: scale from slightly small, fade in,
    // and unblur. The blur is what makes it read as materialising rather than
    // as a window appearing.
    .scaleEffect(hasArrived ? 1 : 0.9)
    .opacity(hasArrived ? 1 : 0)
    .blur(radius: hasArrived ? 0 : 6)
    .animation(motion.expressive, value: hasArrived)
    .onAppear { hasArrived = true }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Display \(number), \(name)")
  }
}
