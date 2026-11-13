import Foundation
import SwiftUI

/// Time-of-day studio atmosphere, evaluated on demand when a surface opens.
///
/// Zero background timers (`0.0% CPU while idle`): the mood is resolved from
/// the clock at render time and provides both the subtle 4–6% top atmospheric
/// wash and the companion header greeting for the Menu Bar Popover.
enum AmbientDaylightMood: String, CaseIterable, Sendable, Equatable {
  case morning
  case afternoon
  case evening

  /// Resolves the studio mood for a given hour (`0...23`).
  static func mood(forHour hour: Int) -> AmbientDaylightMood {
    switch hour {
    case 6..<12: .morning
    case 12..<18: .afternoon
    default: .evening
    }
  }

  /// Resolves the studio mood for `date` using `calendar`.
  static func current(
    for date: Date = Date(),
    calendar: Calendar = .current
  ) -> AmbientDaylightMood {
    let hour = calendar.component(.hour, from: date)
    return mood(forHour: hour)
  }

  /// Warm personal companion greeting title.
  var greetingTitle: String {
    switch self {
    case .morning: "Guten Morgen im Studio"
    case .afternoon: "Goldener Nachmittag"
    case .evening: "Gemütlicher Feierabend"
    }
  }

  /// Editorial companion subtitle.
  var greetingSubtitle: String {
    switch self {
    case .morning: "Frisches Tageslicht · bereit für klaren Fokus"
    case .afternoon: "Warmes Studiolicht · ausgewogene Kontraste"
    case .evening: "Sanfte Bernsteinglut · schont deine Augen"
    }
  }

  /// SF Symbol representing the time of day.
  var symbolName: String {
    switch self {
    case .morning: "sun.haze.fill"
    case .afternoon: "sun.max.fill"
    case .evening: "moon.stars.fill"
    }
  }

  /// Warm orb color for companion badges.
  var orbColor: Color {
    switch self {
    case .morning: Color(.sRGB, red: 0.961, green: 0.620, blue: 0.235)
    case .afternoon: Color(.sRGB, red: 0.918, green: 0.518, blue: 0.176)
    case .evening: Color(.sRGB, red: 0.847, green: 0.431, blue: 0.188)
    }
  }

  /// Subtle 4–6% top atmospheric tint for popover, sidebar, and studio headers.
  func topTint(isDark: Bool) -> Color {
    switch self {
    case .morning:
      return Color(.sRGB, red: 1.0, green: 0.706, blue: 0.392, opacity: isDark ? 0.055 : 0.06)
    case .afternoon:
      return Color(.sRGB, red: 0.941, green: 0.588, blue: 0.275, opacity: isDark ? 0.05 : 0.055)
    case .evening:
      return Color(.sRGB, red: 0.784, green: 0.431, blue: 0.235, opacity: isDark ? 0.06 : 0.05)
    }
  }
}

/// Calm, zero-CPU top daylight & display-accent wash replacing the old blurred blobs.
///
/// Renders a static, ultra-soft top linear gradient (`4–6%` opacity) that gives
/// the window and popover a living time-of-day studio atmosphere without any
/// offscreen blur passes or continuous animations (`0.0% CPU while idle`).
struct AmbientBackdrop: View {
  let accent: Color
  var intensity: Double?
  var isVisible: Bool = true
  var mood: AmbientDaylightMood = .current()

  @Environment(\.theme) private var theme

  private var strength: Double { theme.ambientIntensity * (intensity ?? 1) }

  var body: some View {
    if strength <= 0 {
      EmptyView()
    } else {
      LinearGradient(
        colors: [
          mood.topTint(isDark: theme.isDark),
          accent.opacity(min(0.045 * strength, 0.08)),
          .clear,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity, maxHeight: 180, alignment: .top)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
