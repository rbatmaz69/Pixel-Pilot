import Foundation
import os

/// "When this app is in front, use that preset."
///
/// **Rules point at presets, not at raw numbers.** That reuses the preset
/// editor, the preset hotkeys, the summaries and the apply path, instead of
/// building a second parallel model of what a display should be set to. It also
/// dissolves the question of what happens when you leave an app: presets are
/// absolute, so leaving simply means the next matching rule — or the fallback —
/// applies. There is nothing to remember and nothing to restore.
public struct AppRule: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  public var bundleIdentifier: String
  /// For showing in the list. The bundle identifier is what actually matches.
  public var name: String
  public var presetID: UUID

  public init(id: UUID = UUID(), bundleIdentifier: String, name: String, presetID: UUID) {
    self.id = id
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.presetID = presetID
  }
}

/// Stores app rules, and the preset to fall back to.
///
/// Built like `PresetStore`: one JSON blob in `UserDefaults` behind a lock, no
/// SwiftUI, no observation. `AppModel` republishes it for the views.
public final class AppRuleStore: @unchecked Sendable {
  public static let shared = AppRuleStore()

  private enum Key {
    static let rules = "appRules"
    static let fallback = "appRuleFallbackPreset"
  }

  private let defaults: UserDefaults
  private let lock = NSLock()
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "apprules")

  private var storage: [AppRule]
  private var fallbackStorage: UUID?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.storage = Self.decode([AppRule].self, from: defaults, key: Key.rules) ?? []
    self.fallbackStorage = Self.decode(UUID.self, from: defaults, key: Key.fallback)
  }

  public var rules: [AppRule] {
    lock.withLock { storage }
  }

  /// The preset applied when nothing matches, so the state is always defined.
  ///
  /// Without it, switching from an app with a rule to an app without one would
  /// leave the displays wherever the last rule put them — which reads as the
  /// rule having stuck rather than as no rule applying.
  public var fallbackPresetID: UUID? {
    get { lock.withLock { fallbackStorage } }
    set {
      lock.lock()
      guard fallbackStorage != newValue else {
        lock.unlock()
        return
      }
      fallbackStorage = newValue
      lock.unlock()
      persist(newValue, key: Key.fallback)
    }
  }

  public func rule(forBundleIdentifier identifier: String) -> AppRule? {
    lock.withLock { storage.first { $0.bundleIdentifier == identifier } }
  }

  /// Inserts or replaces.
  ///
  /// One rule per app, enforced here rather than trusted to the UI: two rules
  /// for the same bundle identifier would make which one wins depend on
  /// insertion order, which is invisible and therefore unfixable by whoever
  /// hits it.
  public func save(_ rule: AppRule) {
    lock.lock()
    storage.removeAll { $0.bundleIdentifier == rule.bundleIdentifier && $0.id != rule.id }
    if let index = storage.firstIndex(where: { $0.id == rule.id }) {
      storage[index] = rule
    } else {
      storage.append(rule)
    }
    let snapshot = storage
    lock.unlock()

    persist(snapshot, key: Key.rules)
  }

  public func delete(id: UUID) {
    lock.lock()
    guard storage.contains(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    storage.removeAll { $0.id == id }
    let snapshot = storage
    lock.unlock()

    persist(snapshot, key: Key.rules)
  }

  /// Drops rules pointing at presets that no longer exist, and clears a
  /// fallback that has been deleted. A rule aimed at nothing does nothing, and
  /// does it silently.
  public func pruneMissingPresets(existing: Set<UUID>) {
    lock.lock()
    let before = storage.count
    storage.removeAll { !existing.contains($0.presetID) }
    let snapshot = storage
    let fallbackWasRemoved = fallbackStorage.map { !existing.contains($0) } ?? false
    if fallbackWasRemoved { fallbackStorage = nil }
    lock.unlock()

    if before != snapshot.count { persist(snapshot, key: Key.rules) }
    if fallbackWasRemoved { persist(UUID?.none, key: Key.fallback) }
  }

  // MARK: - Storage

  private func persist(_ value: some Encodable, key: String) {
    do {
      defaults.set(try JSONEncoder().encode(value), forKey: key)
    } catch {
      logger.error("Could not persist '\(key, privacy: .public)': \(error, privacy: .public)")
    }
  }

  private static func decode<T: Decodable>(
    _ type: T.Type, from defaults: UserDefaults, key: String
  ) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}
