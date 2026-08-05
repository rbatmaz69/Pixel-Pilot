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

  /// Whether this display tracks the built-in panel's brightness.
  ///
  /// Off by default, and for the same reason the schedule is: an app that
  /// started moving the brightness on its own without being asked would be a
  /// fault. Never meaningful for the built-in panel itself.
  public var followsBuiltinBrightness: Bool = false

  /// The relationship it tracks by. Taught rather than configured — see
  /// `FollowCurve`.
  public var followCurve: FollowCurve = .identity

  /// Manual override of the derived accent colour, as an index into the palette.
  public var accentOverride: Int?

  /// The chosen white point, in Kelvin. `nil` means neutral — the display is
  /// left completely alone, which is not the same as "set to 6500".
  public var colorTemperatureKelvin: Double?

  /// The chosen finish. `nil` means off, and that is the same distinction
  /// `colorTemperatureKelvin` draws rather than a second way of saying the
  /// same thing: off means there is no table of ours on the display at all,
  /// which is not what "a very flat curve" would mean.
  public var toneCurve: ToneCurve?

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
    followsBuiltinBrightness = try container.decodeIfPresent(
      Bool.self, forKey: .followsBuiltinBrightness
    ) ?? fallback.followsBuiltinBrightness
    // `FollowCurve` degrades key by key on its own, so `decodeIfPresent` is
    // enough here — but it is still wrapped, because a curve written by a build
    // whose anchors had a different shape would otherwise take this display's
    // whole configuration with it.
    followCurve = (try? container.decodeIfPresent(FollowCurve.self, forKey: .followCurve))
      ?? fallback.followCurve
    accentOverride = try container.decodeIfPresent(Int.self, forKey: .accentOverride)
    capabilityString = try container.decodeIfPresent(String.self, forKey: .capabilityString)
    colorTemperatureKelvin = try container.decodeIfPresent(Double.self, forKey: .colorTemperatureKelvin)
    // `ToneCurve` degrades field by field on its own, so `decodeIfPresent`
    // would do — but it is wrapped for the same reason `followCurve` is: a
    // curve written by a build whose shape differed would otherwise take this
    // display's whole configuration with it, and losing a finish is a far
    // smaller loss than losing every setting behind it.
    toneCurve = try? container.decodeIfPresent(ToneCurve.self, forKey: .toneCurve)
    colorCapabilities = try? container.decodeIfPresent(
      DisplayCapabilities.self, forKey: .colorCapabilities
    )
  }

  /// Whether this configuration delivers *brightness* through the gamma table.
  ///
  /// Callers need this when switching strategies: gamma is global to the display
  /// and survives the controller that set it, so it has to be cleared explicitly
  /// rather than left behind when a display stops using it.
  ///
  /// Warmth and the finish are deliberately not counted, even though they are
  /// written to the same table. They are not ways of delivering brightness, and
  /// changing how brightness is delivered is no reason to discard either of
  /// them — which is exactly what the one caller does with the answer.
  public var usesGamma: Bool {
    brightnessStrategy == .gamma || extraDimmingEnabled
  }
}

/// Which end of the theme the interface is drawn at.
///
/// Neither end is grey: "light" is a pale wash of the chosen colour and "dark"
/// is a deep one. The distinction exists because the surrounding system chrome
/// — menus, the titlebar, scrollbars — resolves against an `NSAppearance`, and
/// that has to agree with how light the app's own surfaces are.
public enum ThemeMode: String, Codable, Sendable, CaseIterable {
  /// Follow the system's light/dark setting.
  case system
  case light
  case dark

  public var displayName: String {
    switch self {
    case .system: "Automatic"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// How much of the chosen colour a surface carries, and what it is made of.
///
/// The second axis of the theme, and deliberately orthogonal to the first. The
/// two tones answer *which* colour the app is; this answers *how much of it you
/// see*. They are separate because someone who wants a teal app does not
/// thereby want a quiet one, and the two questions had been welded together by
/// a handful of blend amounts nobody could reach.
///
/// The boundary is worth stating because it is the thing that will be tested by
/// the next feature: a style governs **colour and material only**. It never
/// changes a corner radius and never changes a spring. `Layout` stays a set of
/// plain statics and `Motion` is untouched, so a style can be chosen without
/// asking whether it also moved the furniture.
public enum ThemeStyle: String, Codable, Sendable, CaseIterable {
  /// The look the app shipped with: surfaces mostly drained toward white or
  /// black, real material where there is something behind it to refract.
  case glass
  /// The same eight tones, mixed far less. Every surface carries the colour,
  /// rims and fills are at strength, and the material stays.
  case vivid
  /// No material, no gradients, no drift. The field is one flat colour and a
  /// card is told apart by its edge rather than by its depth.
  case flat

  public var displayName: String {
    switch self {
    case .glass: "Glass"
    case .vivid: "Vivid"
    case .flat: "Flat"
    }
  }

  /// One line under the picker, because three words on a segment cannot say
  /// what changes and the difference is worth a sentence.
  public var summary: String {
    switch self {
    case .glass: "Translucent, soft-edged, the colour kept quiet."
    case .vivid: "Every surface carries the colour at strength."
    case .flat: "No material and no gradients — colour and clear edges."
    }
  }
}

/// Which screen a brightness or volume key is aimed at.
///
/// Two defensible answers, and they are not the same question phrased twice.
/// One says *the screen I am pointing at*, the other *the screen I am working
/// on*, and they part company constantly: the pointer spends most of its life
/// parked wherever it was last put down, which is very often not where the
/// window being typed into is.
/// The third is not a third answer to that question — it declines it. With
/// several monitors on one desk, the room got darker for all of them, and
/// aiming at one is the wrong shape entirely.
public enum KeyTarget: String, Codable, Sendable, CaseIterable {
  /// The screen holding the frontmost application's focused window.
  case focusedWindow
  /// The screen the pointer is over. What the app did before there was a
  /// choice, and a deliberate way to aim: point at a monitor, then press.
  case pointer
  /// Every screen at once, keeping the differences between them.
  case allDisplays

  public var displayName: String {
    switch self {
    case .focusedWindow: "Where you're working"
    case .pointer: "Under the pointer"
    case .allDisplays: "All displays"
    }
  }

  public var summary: String {
    switch self {
    case .focusedWindow: "The screen with the window you're typing in."
    case .pointer: "The screen the pointer happens to be on."
    case .allDisplays:
      "Every screen moves together, keeping the differences you set between them. "
        + "The same group the panel's master slider drives."
    }
  }

  /// Whether a press moves the whole group rather than one screen.
  ///
  /// A separate question from *which* screen, and kept separate on purpose:
  /// even a press that moves everything has one screen it is drawn on, so
  /// `KeyTargetPolicy.target` still has an answer to give. Folding the two
  /// together — a target that sometimes returns a list — would rewrite every
  /// caller that needs exactly one.
  public var movesEveryDisplay: Bool { self == .allDisplays }
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

  /// Which screen the keys act on.
  ///
  /// Defaults to the focused window rather than the pointer, which is a change
  /// of behaviour and deliberate: the old answer sent a brightness key to
  /// whichever screen the mouse had been left on, which on a laptop with an
  /// external monitor plugged in is regularly the wrong one — and since the app
  /// took over the built-in panel's keys too, being wrong there means dimming a
  /// screen nobody was looking at.
  public var keyTarget: KeyTarget = .focusedWindow
  /// Step size for one press of a brightness or volume key, as a fraction.
  public var keyStep: Double = 1.0 / 16.0
  /// Finer steps while Shift+Option is held, matching macOS convention.
  public var fineKeyStep: Double = 1.0 / 64.0
  public var launchAtLogin: Bool = false

  /// Whether the first-run introduction has been seen.
  ///
  /// Written when it is dismissed, whether it was completed or skipped —
  /// showing it again to someone who chose to skip it is worse than never
  /// having shown it.
  public var hasCompletedOnboarding: Bool = false

  /// The day schedule. Disabled by default; an app that started changing the
  /// brightness on its own without being asked would be a fault, not a feature.
  public var schedule: DaySchedule = .init()

  /// Where sunrise happens, to one decimal place — about 11 km, which is more
  /// precision than sunrise needs and much less than a location.
  ///
  /// Optional in both senses: the schedule works on clock times without it, and
  /// it is only ever filled in by someone explicitly choosing solar stops.
  public var latitude: Double?
  public var longitude: Double?

  /// Whether the trackpad taps back at end stops, detents and confirmations.
  ///
  /// On by default, and deliberately *not* tied to Reduce Motion. That setting
  /// is about visible movement, and this app answers it by removing animation
  /// from the hierarchy outright — which takes away exactly the visual cues a
  /// haptic stands in for. macOS has its own switch for feedback, in Trackpad
  /// settings, and the system's feedback performer already honours it; this one
  /// is here so the app can be told to be quiet on its own.
  public var hapticsEnabled: Bool = true

  /// The interface colour, as an index into the accent palette.
  ///
  /// Stored as an index rather than as a colour for the same reason
  /// `DisplaySettings.accentOverride` is: the palette is curated, and a stored
  /// hex value would outlive a tone being retuned.
  public var themeToneIndex: Int = 0

  /// The colour the windows and menus are made of, as an index into the same
  /// palette.
  ///
  /// `nil` means "whatever the accent is", which is both the default and what
  /// the interface looked like before the two could be chosen apart. Stored as
  /// an optional rather than defaulting to the accent's index, so following it
  /// keeps working when the accent is changed later.
  public var themeBackdropToneIndex: Int?

  /// Whether those colours are drawn pale or deep, and whether the system
  /// decides.
  public var themeMode: ThemeMode = .system

  /// How much of those colours reaches the surface, and out of what.
  ///
  /// `.glass` by default, and that is not a taste call: it is what the app
  /// looked like before there was anything to choose, so an existing
  /// installation comes through an update unchanged.
  public var themeStyle: ThemeStyle = .glass

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
    keyTarget = try container.decodeIfPresent(KeyTarget.self, forKey: .keyTarget)
      ?? fallback.keyTarget
    keyStep = try container.decodeIfPresent(Double.self, forKey: .keyStep) ?? fallback.keyStep
    fineKeyStep = try container.decodeIfPresent(Double.self, forKey: .fineKeyStep) ?? fallback.fineKeyStep
    launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
    hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? fallback.hapticsEnabled
    themeToneIndex = try container.decodeIfPresent(Int.self, forKey: .themeToneIndex)
      ?? fallback.themeToneIndex
    themeBackdropToneIndex = try container.decodeIfPresent(
      Int.self, forKey: .themeBackdropToneIndex
    )
    themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? fallback.themeMode
    themeStyle = try container.decodeIfPresent(ThemeStyle.self, forKey: .themeStyle)
      ?? fallback.themeStyle
    // `try?` for the composite, same reasoning as `DisplaySettings.timing`.
    schedule = (try? container.decodeIfPresent(DaySchedule.self, forKey: .schedule)) ?? fallback.schedule
    latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
    longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    // Absent means an existing installation, which has plainly already got
    // past the first run — so the default when decoding is the opposite of the
    // default for a fresh one.
    hasCompletedOnboarding = try container.decodeIfPresent(
      Bool.self, forKey: .hasCompletedOnboarding
    ) ?? true
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
