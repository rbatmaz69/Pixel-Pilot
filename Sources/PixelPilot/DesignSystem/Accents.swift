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
