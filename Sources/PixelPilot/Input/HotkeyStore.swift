import Foundation
import os

/// Persists the user's global shortcuts.
///
/// Deliberately separate from `Preferences` in PixelPilotCore: `Shortcut` is
/// built on Carbon key codes, and dragging that into the UI-free core to store
/// two integers would be the wrong trade.
@MainActor
@Observable
final class HotkeyStore {
  private static let defaultsKey = "hotkeys"

  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "hotkeys")

  private(set) var shortcuts: [HotkeyCenter.Action: Shortcut] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.shortcuts = Self.load(from: defaults)
  }

  func shortcut(for action: HotkeyCenter.Action) -> Shortcut? {
    shortcuts[action]
  }

  /// Drops bindings whose preset no longer exists, so a deleted preset does not
  /// leave a shortcut registered that quietly does nothing.
  func pruneMissingPresets(existing ids: Set<UUID>) {
    let stale = shortcuts.keys.filter { action in
      if case let .preset(id) = action { return !ids.contains(id) }
      return false
    }
    guard !stale.isEmpty else { return }
    for action in stale {
      shortcuts.removeValue(forKey: action)
    }
    persist()
  }

  func set(_ shortcut: Shortcut?, for action: HotkeyCenter.Action) {
    if let shortcut {
      // The same combination cannot drive two actions; the newest wins.
      for (existing, value) in shortcuts where value == shortcut && existing != action {
        shortcuts.removeValue(forKey: existing)
      }
      shortcuts[action] = shortcut
    } else {
      shortcuts.removeValue(forKey: action)
    }
    persist()
  }

  /// No shortcuts are registered out of the box. Anything we picked would risk
  /// silently overriding something the user already relies on.
  ///
  /// Unknown keys are dropped rather than failing the whole load — a shortcut
  /// bound to a preset that no longer exists should cost that one binding, not
  /// all of them.
  private static func load(from defaults: UserDefaults) -> [HotkeyCenter.Action: Shortcut] {
    guard let data = defaults.data(forKey: defaultsKey),
          let raw = try? JSONDecoder().decode([String: Shortcut].self, from: data)
    else { return [:] }

    return raw.reduce(into: [:]) { result, entry in
      if let action = HotkeyCenter.Action(storageKey: entry.key) {
        result[action] = entry.value
      }
    }
  }

  private func persist() {
    let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.storageKey, $0.value) })
    do {
      defaults.set(try JSONEncoder().encode(raw), forKey: Self.defaultsKey)
    } catch {
      logger.error("Could not persist hotkeys: \(error, privacy: .public)")
    }
  }
}
