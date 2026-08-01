import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Preferences")
struct PreferencesTests {
  /// A throwaway defaults suite, so tests never touch the real preferences.
  private func makeDefaults() -> UserDefaults {
    let name = "dev.rb.pixelpilot.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private let key = DisplayKey(rawValue: "4485219c2d511fb4")

  @Test("An unknown display returns defaults rather than nil")
  func defaultsForUnknownDisplay() {
    let preferences = Preferences(defaults: makeDefaults())
    let settings = preferences.settings(for: key)
    #expect(settings.brightnessStrategy == .automatic)
    #expect(settings.capabilities == nil)
    #expect(!settings.extraDimmingEnabled)
  }

  @Test("Changes persist and reload")
  func roundTrip() {
    let defaults = makeDefaults()

    let first = Preferences(defaults: defaults)
    first.update(key) {
      $0.lastKnownName = "U32T1"
      $0.brightnessStrategy = .ddc
      $0.extraDimmingEnabled = true
      $0.timing = .relaxed
    }

    // A fresh instance reads from storage, not from the first one's cache.
    let second = Preferences(defaults: defaults)
    let settings = second.settings(for: key)
    #expect(settings.lastKnownName == "U32T1")
    #expect(settings.brightnessStrategy == .ddc)
    #expect(settings.extraDimmingEnabled)
    #expect(settings.timing == .relaxed)
  }

  /// Capabilities are the expensive thing to recompute — six DDC round trips —
  /// so they above all must survive a relaunch.
  @Test("Cached capabilities survive a relaunch")
  func capabilitiesPersist() {
    let defaults = makeDefaults()

    Preferences(defaults: defaults).update(key) {
      $0.capabilities = DisplayCapabilities(features: [
        .luminance: .supported(current: 100, maximum: 100),
        .audioSpeakerVolume: .implausible(current: 100, maximum: 0xFFFF, reason: "stub"),
      ])
    }

    let restored = Preferences(defaults: defaults).settings(for: key).capabilities
    #expect(restored?.isUsable(.luminance) == true)
    #expect(restored?.isUsable(.audioSpeakerVolume) == false)
  }

  @Test("Settings are per display, not shared")
  func isolation() {
    let preferences = Preferences(defaults: makeDefaults())
    let other = DisplayKey(rawValue: "ffffffffffffffff")

    preferences.update(key) { $0.brightnessStrategy = .gamma }

    #expect(preferences.settings(for: key).brightnessStrategy == .gamma)
    #expect(preferences.settings(for: other).brightnessStrategy == .automatic)
  }

  /// An idle app must not be writing to disk. A mutation that changes nothing
  /// has to be a no-op all the way down.
  @Test("A no-op update does not write")
  func noOpDoesNotPersist() {
    let defaults = makeDefaults()
    let preferences = Preferences(defaults: defaults)

    preferences.update(key) { $0.brightnessStrategy = .ddc }
    let afterFirstWrite = defaults.data(forKey: "displays")

    preferences.update(key) { $0.brightnessStrategy = .ddc }
    #expect(defaults.data(forKey: "displays") == afterFirstWrite)
  }

  @Test("Known displays are listed for the settings UI")
  func listsKnownDisplays() {
    let preferences = Preferences(defaults: makeDefaults())
    preferences.update(key) { $0.lastKnownName = "U32T1" }
    preferences.update(DisplayKey(rawValue: "abcd")) { $0.lastKnownName = "Other" }

    let known = preferences.knownDisplays()
    #expect(known.count == 2)
    #expect(known[key]?.lastKnownName == "U32T1")
  }

  @Test("Forgetting a display removes it")
  func forget() {
    let preferences = Preferences(defaults: makeDefaults())
    preferences.update(key) { $0.brightnessStrategy = .gamma }
    preferences.forget(key)

    #expect(preferences.knownDisplays().isEmpty)
    #expect(preferences.settings(for: key).brightnessStrategy == .automatic)
  }

  @Test("Global settings round-trip independently of displays")
  func globalSettings() {
    let defaults = makeDefaults()

    Preferences(defaults: defaults).updateGlobal {
      $0.mediaKeysEnabled = false
      $0.keyStep = 1.0 / 32.0
    }

    let restored = Preferences(defaults: defaults).global
    #expect(!restored.mediaKeysEnabled)
    #expect(restored.keyStep == 1.0 / 32.0)
    #expect(restored.showsOSD, "untouched fields keep their defaults")
  }

  // MARK: - Forward compatibility

  // Every stored blob was written by an older build, and every new preference
  // adds a key that build never wrote. `decode` swallows the error with `try?`,
  // so a decoder that insists on the missing key does not fail loudly — it
  // silently resets every setting the user has ever changed. These tests stand
  // in for that older build.

  @Test("A blob missing newer keys keeps the values it does carry")
  func globalSettingsToleratesMissingKeys() {
    let defaults = makeDefaults()
    // What a build predating `hidMediaKeysEnabled`, `keyStep` and the rest wrote.
    defaults.set(Data(#"{"mediaKeysEnabled":false}"#.utf8), forKey: "global")

    let restored = Preferences(defaults: defaults).global
    #expect(!restored.mediaKeysEnabled, "the one stored value must survive")
    #expect(restored.keyStep == 1.0 / 16.0, "absent keys fall back to their defaults")
    #expect(restored.hidMediaKeysEnabled)
    #expect(restored.showsOSD)
  }

  @Test("Display settings missing newer keys keep the values they do carry")
  func displaySettingsToleratesMissingKeys() {
    let defaults = makeDefaults()
    defaults.set(
      Data(#"{"4485219c2d511fb4":{"lastKnownName":"U32T1","brightnessStrategy":"gamma"}}"#.utf8),
      forKey: "displays"
    )

    let restored = Preferences(defaults: defaults).settings(for: key)
    #expect(restored.lastKnownName == "U32T1")
    #expect(restored.brightnessStrategy == .gamma)
    #expect(restored.timing == .default, "absent keys fall back to their defaults")
    #expect(restored.respondsToMediaKeys)
    #expect(!restored.extraDimmingEnabled)
  }

  /// The one field whose decoding default is the opposite of its declared one.
  /// An existing installation has plainly got past the first run already, so
  /// an update must not put the introduction in front of it.
  @Test("An existing installation is not shown the introduction again")
  func onboardingIsNotReplayedOnUpdate() {
    let defaults = makeDefaults()
    defaults.set(Data(#"{"mediaKeysEnabled":true}"#.utf8), forKey: "global")

    #expect(Preferences(defaults: defaults).global.hasCompletedOnboarding)
    #expect(!GlobalSettings().hasCompletedOnboarding, "but a fresh install does see it")
  }

  /// The newest key, and the one most recently at risk of the bug above.
  @Test("The theme style survives a round trip")
  func themeStyleRoundTrips() {
    let defaults = makeDefaults()
    let preferences = Preferences(defaults: defaults)
    preferences.updateGlobal { $0.themeStyle = .vivid }

    #expect(Preferences(defaults: defaults).global.themeStyle == .vivid)
  }

  /// What a build predating the style wrote. Everything it *did* write has to
  /// come through, and the style has to land on the look that build had.
  @Test("A blob written before the style keeps its settings")
  func themeStyleAbsentKeepsTheRest() {
    let defaults = makeDefaults()
    defaults.set(
      Data(#"{"themeToneIndex":5,"themeMode":"dark","hapticsEnabled":false}"#.utf8),
      forKey: "global"
    )

    let restored = Preferences(defaults: defaults).global
    #expect(restored.themeToneIndex == 5)
    #expect(restored.themeMode == .dark)
    #expect(!restored.hapticsEnabled)
    #expect(restored.themeStyle == .glass, "which is what that build looked like")
  }

  /// The other half of the promise: a blob written by a *newer* build must not
  /// take the settings down with it either.
  @Test("Unknown keys from a newer build are ignored")
  func toleratesUnknownKeys() {
    let defaults = makeDefaults()
    defaults.set(Data(#"{"mediaKeysEnabled":false,"somethingFromTheFuture":42}"#.utf8), forKey: "global")

    #expect(!Preferences(defaults: defaults).global.mediaKeysEnabled)
  }
}
