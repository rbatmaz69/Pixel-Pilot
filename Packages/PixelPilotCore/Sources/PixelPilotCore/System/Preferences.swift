import Foundation
import os

/// How brightness reaches a given panel.
public enum BrightnessStrategy: String, Codable, Sendable, CaseIterable {
  /// Resolve from what the display actually supports. The default, and correct
  /// for nearly every panel.
  case automatic
  /// DDC/CI luminance (VCP 0x10) — real backlight control.
  case ddc
  /// Gamma table manipulation. Does not touch the backlight, so it costs
  /// contrast and shows up in screenshots, but works on anything.
  case gamma
  /// The built-in Apple panel, via DisplayServices.
  case native

  public var displayName: String {
    switch self {
    case .automatic: "Automatic"
    case .ddc: "DDC/CI"
    case .gamma: "Software (gamma)"
    case .native: "Native"
    }
  }
}

/// Everything remembered about one physical panel.
public struct DisplaySettings: Codable, Sendable, Equatable {
  /// Kept only so the settings UI can name a display that is currently
  /// disconnected. Never used for identification — that is the `DisplayKey`.
  public var lastKnownName: String = ""

  public var brightnessStrategy: BrightnessStrategy = .automatic
  public var timing: DDCTiming = .default

  /// Result of the one-shot capability probe. Present means "already probed";
  /// probing again costs a DDC round trip per feature.
  public var capabilities: DisplayCapabilities?

  /// Continue dimming with gamma once DDC brightness reaches zero.
  public var extraDimmingEnabled: Bool = false

  /// Whether the brightness keys act on this display.
  public var respondsToMediaKeys: Bool = true

  /// Manual override of the derived accent colour, as an index into the palette.
  public var accentOverride: Int?

  public init() {}
}

/// Preferences that are not per-display.
public struct GlobalSettings: Codable, Sendable, Equatable {
  public var mediaKeysEnabled: Bool = true
  public var showsOSD: Bool = true
  /// Step size for one press of a brightness or volume key, as a fraction.
  public var keyStep: Double = 1.0 / 16.0
  /// Finer steps while Shift+Option is held, matching macOS convention.
  public var fineKeyStep: Double = 1.0 / 64.0
  public var launchAtLogin: Bool = false

  public init() {}
}

/// Persisted settings, keyed by `DisplayKey` so they follow the panel rather
/// than the port it happens to be plugged into.
///
/// Backed by `UserDefaults` as a single JSON blob per bucket. That is a
/// deliberate simplification: the data is small, always read as a whole, and
/// keeping it in one place makes it inspectable and hand-editable when a user
/// needs to unstick a misconfigured display.
public final class Preferences: @unchecked Sendable {
  public static let shared = Preferences()

  private enum Key {
    static let displays = "displays"
    static let global = "global"
  }

  private let defaults: UserDefaults
  private let lock = NSLock()
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "preferences")

  private var displayCache: [String: DisplaySettings]
  private var globalCache: GlobalSettings

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.displayCache = Self.decode([String: DisplaySettings].self, from: defaults, key: Key.displays) ?? [:]
    self.globalCache = Self.decode(GlobalSettings.self, from: defaults, key: Key.global) ?? GlobalSettings()
  }

  // MARK: - Per display

  public func settings(for key: DisplayKey) -> DisplaySettings {
    lock.withLock { displayCache[key.rawValue] ?? DisplaySettings() }
  }

  /// Read-modify-write for one display. Persists only when something changed —
  /// an idle app should not be writing to disk.
  public func update(_ key: DisplayKey, _ mutate: (inout DisplaySettings) -> Void) {
    lock.lock()
    var settings = displayCache[key.rawValue] ?? DisplaySettings()
    let before = settings
    mutate(&settings)
    guard settings != before else {
      lock.unlock()
      return
    }
    displayCache[key.rawValue] = settings
    let snapshot = displayCache
    lock.unlock()

    persist(snapshot, key: Key.displays)
  }

  /// Every panel we have ever seen, for the settings UI.
  public func knownDisplays() -> [DisplayKey: DisplaySettings] {
    lock.withLock {
      Dictionary(uniqueKeysWithValues: displayCache.map { (DisplayKey(rawValue: $0.key), $0.value) })
    }
  }

  public func forget(_ key: DisplayKey) {
    lock.lock()
    guard displayCache.removeValue(forKey: key.rawValue) != nil else {
      lock.unlock()
      return
    }
    let snapshot = displayCache
    lock.unlock()

    persist(snapshot, key: Key.displays)
  }

  // MARK: - Global

  public var global: GlobalSettings {
    lock.withLock { globalCache }
  }

  public func updateGlobal(_ mutate: (inout GlobalSettings) -> Void) {
    lock.lock()
    var settings = globalCache
    let before = settings
    mutate(&settings)
    guard settings != before else {
      lock.unlock()
      return
    }
    globalCache = settings
    lock.unlock()

    persist(settings, key: Key.global)
  }

  // MARK: - Storage

  private func persist<T: Encodable>(_ value: T, key: String) {
    do {
      defaults.set(try JSONEncoder().encode(value), forKey: key)
    } catch {
      // Losing a preference is not worth taking the app down for.
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
