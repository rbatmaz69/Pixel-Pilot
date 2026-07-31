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

  /// The chosen white point, in Kelvin. `nil` means neutral — the display is
  /// left completely alone, which is not the same as "set to 6500".
  public var colorTemperatureKelvin: Double?

  /// Result of the on-demand colour probe, cached like `capabilities` is.
  /// Present means "already asked"; absent means the colour card has never
  /// been opened for this panel.
  public var colorCapabilities: DisplayCapabilities?

  /// The display's own capability string, once read.
  ///
  /// Cached separately from `capabilities` because it is far more expensive —
  /// a dozen or more round trips rather than six — and because the raw text is
  /// what the diagnostics view shows when a panel reports something odd.
  public var capabilityString: String?

  public init() {}

  /// Written by hand rather than synthesised, for the reason spelled out on
  /// `GlobalSettings.init(from:)`: the synthesised version throws on a key that
  /// an older build never wrote, and `Preferences.decode` turns a throw into a
  /// full reset.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = DisplaySettings()
    lastKnownName = try container.decodeIfPresent(String.self, forKey: .lastKnownName)
      ?? fallback.lastKnownName
    brightnessStrategy = try container.decodeIfPresent(BrightnessStrategy.self, forKey: .brightnessStrategy)
      ?? fallback.brightnessStrategy
    // The two composites use `try?` rather than `try`. `decodeIfPresent` covers
    // a key that is absent, but not a key that is present and was written by a
    // build whose *nested* shape differed — that still throws, and one changed
    // field inside `DDCTiming` would otherwise take this whole display's
    // settings with it. Degrading is the right answer for both: timing falls
    // back to the standard profile, and a lost capability cache re-probes on the
    // next connect, which is exactly what a display that has never been seen
    // does anyway.
    timing = (try? container.decodeIfPresent(DDCTiming.self, forKey: .timing)) ?? fallback.timing
    capabilities = try? container.decodeIfPresent(DisplayCapabilities.self, forKey: .capabilities)
    extraDimmingEnabled = try container.decodeIfPresent(Bool.self, forKey: .extraDimmingEnabled)
      ?? fallback.extraDimmingEnabled
    respondsToMediaKeys = try container.decodeIfPresent(Bool.self, forKey: .respondsToMediaKeys)
      ?? fallback.respondsToMediaKeys
    accentOverride = try container.decodeIfPresent(Int.self, forKey: .accentOverride)
    capabilityString = try container.decodeIfPresent(String.self, forKey: .capabilityString)
    colorTemperatureKelvin = try container.decodeIfPresent(Double.self, forKey: .colorTemperatureKelvin)
    colorCapabilities = try? container.decodeIfPresent(
      DisplayCapabilities.self, forKey: .colorCapabilities
    )
  }

  /// Whether this configuration puts anything into the display's gamma table.
  ///
  /// Callers need this when switching strategies: gamma is global to the display
  /// and survives the controller that set it, so it has to be cleared explicitly
  /// rather than left behind when a display stops using it.
  public var usesGamma: Bool {
    brightnessStrategy == .gamma || extraDimmingEnabled
  }
}

/// Preferences that are not per-display.
public struct GlobalSettings: Codable, Sendable, Equatable {
  public var mediaKeysEnabled: Bool = true

  /// Whether to also watch the HID layer, which is what makes brightness keys
  /// work on keyboards macOS does not translate.
  ///
  /// On by default because a key that does nothing is the more common
  /// complaint. But it is a switch rather than an assumption: an open HID
  /// connection costs about 0.33% of a core continuously, and this app is
  /// otherwise at zero when idle. Anyone whose keyboard already works can turn
  /// it off and get that back.
  public var hidMediaKeysEnabled: Bool = true
  public var showsOSD: Bool = true
  /// Step size for one press of a brightness or volume key, as a fraction.
  public var keyStep: Double = 1.0 / 16.0
  /// Finer steps while Shift+Option is held, matching macOS convention.
  public var fineKeyStep: Double = 1.0 / 64.0
  public var launchAtLogin: Bool = false

  /// Whether the trackpad taps back at end stops, detents and confirmations.
  ///
  /// On by default, and deliberately *not* tied to Reduce Motion. That setting
  /// is about visible movement, and this app answers it by removing animation
  /// from the hierarchy outright — which takes away exactly the visual cues a
  /// haptic stands in for. macOS has its own switch for feedback, in Trackpad
  /// settings, and the system's feedback performer already honours it; this one
  /// is here so the app can be told to be quiet on its own.
  public var hapticsEnabled: Bool = true

  public init() {}

  /// Decoded by hand, and this is not boilerplate worth deleting.
  ///
  /// Swift's synthesised `init(from:)` ignores property defaults: a key that is
  /// absent from the stored JSON throws `keyNotFound` rather than falling back.
  /// Every blob on disk was written by an older build, so every preference
  /// added here is a key that build never wrote — and `Preferences.decode`
  /// swallows the throw with `try?` and returns a fresh `GlobalSettings`.
  ///
  /// The failure mode is therefore not a decode error anyone would notice: it
  /// is every setting the user ever changed quietly reverting, once, on the
  /// update that introduced the field. `decodeIfPresent` is what makes adding a
  /// preference a safe thing to do.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = GlobalSettings()
    mediaKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaKeysEnabled)
      ?? fallback.mediaKeysEnabled
    hidMediaKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .hidMediaKeysEnabled)
      ?? fallback.hidMediaKeysEnabled
    showsOSD = try container.decodeIfPresent(Bool.self, forKey: .showsOSD) ?? fallback.showsOSD
    keyStep = try container.decodeIfPresent(Double.self, forKey: .keyStep) ?? fallback.keyStep
    fineKeyStep = try container.decodeIfPresent(Double.self, forKey: .fineKeyStep) ?? fallback.fineKeyStep
    launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
    hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? fallback.hapticsEnabled
  }
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
