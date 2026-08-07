import PixelPilotCore
import SwiftUI

/// Everything in the settings window, as a list you can type at.
///
/// **Hand-written, not derived, and that is the decision this file is about.**
///
/// A derived index would mean every card registering itself — a modifier at
/// thirty-odd call sites, which is one more thing to remember at each of them
/// and one more thing to leave off. It would also index only what happens to
/// have been built: the settings window drops its whole hierarchy when it
/// closes, and a display's seven cards do not exist until somebody has opened
/// that display's page. A search that can only find the pages you have already
/// visited is not a search.
///
/// The cost is drift — a card renamed in its own file and not here. The
/// structural half of that is caught by `SettingsSearchIndexTests`: a page with
/// no entries at all, a duplicate id, an empty keyword list. The wording half
/// cannot be tested by anything, so the mitigation is that this is one file in
/// sidebar order, and a rename is a two-line change a reviewer can see.
@MainActor
enum SettingsSearchIndex {
  static func entries(model: AppModel) -> [SearchEntry<SettingsRoute>] {
    var entries: [SearchEntry<SettingsRoute>] = []

    entries.append(
      card("Overview", page: .overview, keywords: ["status", "everything", "summary", "board"])
    )

    // MARK: Displays

    // Seven cards per display, from one table rather than seven lines each.
    for display in model.displays {
      for card in displayCards {
        entries.append(
          SearchEntry(
            id: "display:\(display.id):\(card.title)",
            title: card.title,
            context: display.name,
            keywords: card.keywords,
            target: .display(display.id)
          )
        )
      }
    }

    entries.append(
      SearchEntry(
        id: "remembered",
        title: "Remembered displays",
        context: "Displays",
        keywords: ["forget", "disconnected", "unplugged", "known", "previous"],
        target: .remembered
      )
    )

    // MARK: App

    entries += [
      card("Welcome guide", page: .general, keywords: ["onboarding", "introduction", "tour", "first run"]),
      card("Colour theme", page: .general,
           keywords: ["color", "accent", "theme", "dark", "light", "glass", "vivid", "flat", "depth", "appearance"]),
      card("Startup", page: .general, keywords: ["login", "launch", "open at login", "autostart", "boot"]),

      card("This version", page: .updates, keywords: ["update", "version", "build", "download", "install", "check"]),
      card("What is new", page: .updates, keywords: ["release notes", "changelog", "changes"]),
      card("Automatic checks", page: .updates, keywords: ["update", "daily", "automatic", "check"]),
      card("What an update costs", page: .updates,
           keywords: ["accessibility", "signature", "permission", "regrant", "ad-hoc"]),

      card("Keyboard keys", page: .keys,
           keywords: ["brightness keys", "media keys", "step", "osd", "indicator", "hud", "target", "pointer"]),
      card("Attention", page: .keys, keywords: ["dim unfocused", "veil", "sink back", "focus", "unfocused"]),
      card("Permissions", page: .keys,
           keywords: ["accessibility", "input monitoring", "grant", "trusted", "privacy", "security"]),
      card("Key detection", page: .keys, keywords: ["hid", "teach", "learn", "keyboard", "usage", "detect"]),

      card("Presets", page: .presets, keywords: ["saved", "scene", "apply", "reorder"]),
      card("Capture the current state", page: .presets, keywords: ["save", "new preset", "capture", "record"]),
      card("Automatic", page: .presets,
           keywords: ["appearance", "dark mode", "light mode", "binding", "system appearance"]),

      card("Through the day", page: .schedule, keywords: ["arc", "timeline", "next change", "day"]),
      card("Stops", page: .schedule, keywords: ["sunrise", "sunset", "solar", "time", "clock", "stop"]),
      card("Where sunrise happens", page: .schedule,
           keywords: ["location", "latitude", "longitude", "coordinate", "solar", "place"]),

      card("Per-app presets", page: .apps, keywords: ["app rule", "application", "per app", "rule", "bundle"]),
      card("Everything else", page: .apps, keywords: ["fallback", "default", "no rule"]),

      card("Your presets", page: .shortcuts, keywords: ["hotkey", "shortcut", "preset", "global"]),
    ]

    // Built from the groups themselves, so a renamed group cannot leave a
    // stale entry behind here.
    for group in HotkeyCenter.Action.Builtin.Group.allCases {
      entries.append(
        card(group.title, page: .shortcuts,
             keywords: ["hotkey", "shortcut", "global", "keyboard", group.rawValue])
      )
    }

    // MARK: What the user made

    // Presets and rules are named by the person using the app, which makes
    // them the most likely thing to be searched for and the only thing the
    // static list above could never contain.
    for preset in model.presetList {
      entries.append(
        SearchEntry(
          id: "preset:\(preset.id)",
          title: preset.name,
          context: "Presets",
          keywords: ["preset", "saved", "apply"],
          target: .app(.presets)
        )
      )
    }

    for rule in model.appRuleList {
      entries.append(
        SearchEntry(
          id: "rule:\(rule.id)",
          title: rule.name,
          context: "Apps",
          keywords: ["app rule", "application", rule.bundleIdentifier],
          target: .app(.apps)
        )
      )
    }

    return entries
  }

  /// The cards every display page has, in the order they appear on it.
  ///
  /// The spelling pairs are here for the same reason they are everywhere else
  /// in this file: the app writes "Colour" and half the people typing at it
  /// will type "color".
  private static let displayCards: [(title: String, keywords: [String])] = [
    ("Controls", ["brightness", "contrast", "volume", "slider"]),
    ("Health", ["dead pixel", "stuck pixel", "test pattern", "check", "reanimate", "defect", "banding"]),
    ("Input and power", ["input source", "hdmi", "displayport", "usb-c", "power", "standby", "switch"]),
    ("Colour", ["color", "warmth", "kelvin", "temperature", "white point", "night"]),
    ("Finish", ["paper", "matte", "ink", "black lift", "white ceiling", "softness", "tone curve"]),
    ("This display", ["strategy", "gamma", "ddc", "timing", "re-probe", "follow", "accent", "media keys"]),
    ("Diagnostics", ["ddc log", "capability string", "features", "reported", "debug", "log"]),
  ]

  private static func card(
    _ title: String, page: AppPage, keywords: [String]
  ) -> SearchEntry<SettingsRoute> {
    SearchEntry(
      id: "\(page.rawValue):\(title)",
      title: title,
      context: page.title,
      keywords: keywords,
      target: .app(page)
    )
  }
}
