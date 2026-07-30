import PixelPilotCore
import SwiftUI

/// Per-display accent colours.
///
/// Each monitor gets a colour derived from its `DisplayKey`, so the same panel
/// looks the same on every launch and two monitors are never confusable at a
/// glance. Nothing is hardcoded to a particular display, and the palette is
/// curated rather than generated — an arbitrary hue from a hash lands on muddy
/// olive often enough to matter.
enum AccentPalette {
  /// Eight tones, tuned to stay legible against both Liquid Glass materials and
  /// the desktop showing through them.
  static let tones: [Color] = [
    Color(.sRGB, red: 0.20, green: 0.51, blue: 0.98), // blue
    Color(.sRGB, red: 0.36, green: 0.75, blue: 0.42), // green
    Color(.sRGB, red: 0.98, green: 0.62, blue: 0.16), // amber
    Color(.sRGB, red: 0.85, green: 0.31, blue: 0.44), // rose
    Color(.sRGB, red: 0.55, green: 0.42, blue: 0.93), // violet
    Color(.sRGB, red: 0.16, green: 0.72, blue: 0.76), // teal
    Color(.sRGB, red: 0.93, green: 0.45, blue: 0.24), // coral
    Color(.sRGB, red: 0.45, green: 0.58, blue: 0.30), // moss
  ]

  /// Deterministic for a given panel. `override` lets a user pick a different
  /// tone when the automatic choice collides with their wallpaper.
  static func color(for key: DisplayKey, override: Int? = nil) -> Color {
    if let override, tones.indices.contains(override) {
      return tones[override]
    }
    return tones[index(for: key)]
  }

  static func index(for key: DisplayKey) -> Int {
    // The key is already a hex digest, so its leading bytes are well
    // distributed — no need to hash it again. Swift's own `hashValue` would be
    // wrong here: it is seeded per process and would give a different colour on
    // every launch.
    let seed = UInt64(key.rawValue.prefix(8), radix: 16) ?? 0
    return Int(seed % UInt64(tones.count))
  }
}

/// The roles one accent plays.
///
/// A single hue has to work as a fill, as a wash behind text, as a hairline and
/// as a glow, and each of those wants a different weight. Deriving them from the
/// one curated tone keeps the palette at eight entries instead of thirty-two,
/// and means a user's accent override reaches every surface at once.
extension Color {
  /// The lighter end of a fill gradient. `mix(with:by:)` rather than a second
  /// hand-tuned palette — eight colours are enough to keep honest.
  var accentLift: Color { mix(with: .white, by: 0.30) }

  /// Surface tint for cards. Deliberately faint: on Liquid Glass every tint
  /// adds to whatever is showing through, and a wash tuned against a plain
  /// background turns muddy over a busy desktop.
  var accentWash: Color { opacity(0.12) }

  /// Hairline around a tinted surface. Enough to give the card an edge when the
  /// wash alone disappears against a light wallpaper.
  var accentRim: Color { opacity(0.30) }

  /// The fill for tracks and progress. Top-lit, the way a physical control
  /// would be — a flat fill next to a morphing handle looks unfinished.
  var accentFill: LinearGradient {
    LinearGradient(colors: [accentLift, self], startPoint: .top, endPoint: .bottom)
  }

  /// The glow under an active control. Used at zero opacity when inactive, so
  /// the shadow can be animated rather than inserted.
  func accentGlow(_ active: Bool) -> Color { opacity(active ? 0.45 : 0) }

  /// The accent as type.
  ///
  /// The palette is tuned for fills, and a fill colour is not a text colour:
  /// set as 12pt type, the amber and the teal are unreadable on light
  /// backgrounds and the moss disappears on dark ones. Pulling each tone toward
  /// the foreground fixes all eight at once and keeps them recognisably
  /// themselves.
  func accentText(_ scheme: ColorScheme) -> Color {
    mix(with: scheme == .dark ? .white : .black, by: 0.3)
  }
}
