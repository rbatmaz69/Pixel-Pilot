import CoreGraphics
import Foundation
import PixelPilotCore
import Testing

@testable import PixelPilot

/// Hands back whatever display set the test asks for.
///
/// Exists because unplugging a monitor by hand is the only other way to reach
/// these paths, and they are the ones that go wrong quietly: a display that
/// comes back with a different `CGDirectDisplayID`, or one that leaves while
/// dimmed.
private final class StubDiscovery: DisplayDiscovering, @unchecked Sendable {
  private let lock = NSLock()
  private var _displays: [DiscoveredDisplay]
  private var _callCount = 0

  init(displays: [DiscoveredDisplay] = []) {
    self._displays = displays
  }

  var callCount: Int { lock.withLock { _callCount } }

  func set(_ displays: [DiscoveredDisplay]) {
    lock.withLock { _displays = displays }
  }

  func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay] {
    lock.withLock {
      _callCount += 1
      return _displays
    }
  }
}

private func makeDisplay(
  id: CGDirectDisplayID, key: String, name: String
) -> DiscoveredDisplay {
  DiscoveredDisplay(
    displayID: id, key: DisplayKey(rawValue: key), name: name, isBuiltin: false
  )
}

private func makeBuiltinDisplay(
  id: CGDirectDisplayID, key: String, name: String = "Built-in Display"
) -> DiscoveredDisplay {
  DiscoveredDisplay(
    displayID: id, key: DisplayKey(rawValue: key), name: name, isBuiltin: true
  )
}

/// A throwaway defaults suite, so tests never touch the real preferences.
private func makeDefaults() -> UserDefaults {
  let name = "dev.rb.pixelpilot.apptests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

private func makePreferences() -> Preferences {
  Preferences(defaults: makeDefaults())
}

/// A model wired to throwaway storage throughout, for the preset tests.
@MainActor
private func makeModelWithPresets(displays: [DiscoveredDisplay] = []) -> AppModel {
  let model = AppModel(
    discovery: StubDiscovery(displays: displays),
    gamma: GammaDimmer(),
    preferences: makePreferences(),
    presets: PresetStore(defaults: makeDefaults()),
    keyBindings: KeyBindingStore(defaults: makeDefaults())
  )
  model.refresh()
  return model
}

@MainActor
@Suite("App model")
struct AppModelTests {
  @Test("Discovered displays become view models")
  func buildsViewModels() {
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "U32T1"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )

    model.refresh()

    #expect(model.displays.count == 2)
    #expect(model.displays.map(\.name) == ["U32T1", "Second"])
  }

  /// The property that matters when a monitor is replugged: macOS hands out a
  /// different `CGDirectDisplayID`, so identity has to come from the
  /// `DisplayKey` or every setting is lost on reconnect.
  @Test("A display reconnecting under a new ID keeps its identity")
  func survivesReconnectWithNewDisplayID() {
    let discovery = StubDiscovery(displays: [makeDisplay(id: 3, key: "aaa", name: "U32T1")])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()
    let before = model.displays.first?.id

    // Unplugged and plugged back in: same panel, new CoreGraphics id.
    discovery.set([makeDisplay(id: 9, key: "aaa", name: "U32T1")])
    model.refresh()

    #expect(model.displays.first?.id == before)
    #expect(model.displays.first?.displayID == 9)
  }

  @Test("A display that goes away is dropped")
  func dropsDisappearedDisplays() {
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "First"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()

    discovery.set([makeDisplay(id: 1, key: "aaa", name: "First")])
    model.refresh()

    #expect(model.displays.count == 1)
    #expect(model.displays.first?.name == "First")
  }

  /// A monitor unplugged while dimmed would otherwise keep its gamma entry
  /// forever — and have it reasserted onto whatever display inherits its id.
  @Test("Gamma entries for departed displays are cleaned up")
  func prunesGammaOnDisappearance() {
    let gamma = GammaDimmer()
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "First"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(discovery: discovery, gamma: gamma, preferences: makePreferences())
    model.refresh()

    gamma.setDimming(0.5, for: 1)
    gamma.setDimming(0.5, for: 2)
    #expect(gamma.dimmedDisplays.count == 2)

    discovery.set([makeDisplay(id: 1, key: "aaa", name: "First")])
    model.refresh()

    #expect(gamma.dimmedDisplays == [1])
  }

  @Test("No displays is a valid state, not a crash")
  func handlesNoDisplays() {
    let discovery = StubDiscovery(displays: [])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()

    #expect(model.displays.isEmpty)
    #expect(model.focusedDisplay == nil)
  }

  /// The laptop-only case, which the keys used to be switched off for entirely.
  /// Now the built-in panel is a legitimate target, so it has to survive
  /// discovery and be what a key press is pointed at.
  @Test("A built-in panel on its own is still a focused display")
  func builtinOnlyIsFocusable() {
    let discovery = StubDiscovery(displays: [makeBuiltinDisplay(id: 1, key: "builtin")])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()

    #expect(model.displays.count == 1)
    #expect(model.focusedDisplay?.isBuiltin == true)
  }

  @Test("Quitting restores every dimmed display")
  func stopClearsGamma() {
    let gamma = GammaDimmer()
    let model = AppModel(
      discovery: StubDiscovery(), gamma: gamma, preferences: makePreferences()
    )

    gamma.setDimming(0.4, for: 1)
    model.stop()

    #expect(gamma.dimmedDisplays.isEmpty, "a dimmed display left behind looks like broken hardware")
  }

  /// Each refresh must ask again. Caching here would mean a monitor plugged in
  /// after launch never appears.
  @Test("Every refresh re-asks for the display list")
  func refreshAlwaysRediscovers() {
    let discovery = StubDiscovery(displays: [makeDisplay(id: 1, key: "aaa", name: "First")])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )

    model.refresh()
    model.refresh()
    model.refresh()

    #expect(discovery.callCount == 3)
  }

  // MARK: - The preset mirror

  // `PresetStore` lives in the UI-free package and is not observable, and a
  // `let` property would not be instrumented by `@Observable` even if it were.
  // A view reading the store directly establishes no dependency on it and never
  // redraws. These tests pin the mirror that replaced that read — they are the
  // only thing standing between a preset list and rows that are simply wrong.

  @Test("Capturing a preset shows up in the published list")
  func captureUpdatesPresetList() {
    let model = makeModelWithPresets(displays: [makeDisplay(id: 1, key: "aaa", name: "U32T1")])
    #expect(model.presetList.isEmpty)

    let preset = model.captureCurrentState(name: "Evening", symbolName: "moon")

    #expect(model.presetList.map(\.id) == [preset.id])
    #expect(model.presetList.first?.name == "Evening")
  }

  /// The path with no coincidental `@State` write to redraw it, and therefore
  /// the one that was visibly broken.
  @Test("Deleting a preset removes it from the published list")
  func deleteUpdatesPresetList() {
    let model = makeModelWithPresets()
    let first = model.captureCurrentState(name: "Day", symbolName: "sun.max")
    let second = model.captureCurrentState(name: "Night", symbolName: "moon")

    model.deletePreset(id: first.id)

    #expect(model.presetList.map(\.id) == [second.id])
  }

  @Test("Reordering presets is published")
  func moveUpdatesPresetList() {
    let model = makeModelWithPresets()
    let first = model.captureCurrentState(name: "Day", symbolName: "sun.max")
    let second = model.captureCurrentState(name: "Night", symbolName: "moon")

    model.movePresets(fromOffsets: IndexSet(integer: 1), toOffset: 0)

    #expect(model.presetList.map(\.id) == [second.id, first.id])
  }

  @Test("Appearance bindings are published")
  func appearanceBindingsAreMirrored() {
    let model = makeModelWithPresets()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")

    model.updateAppearanceBindings {
      $0.isEnabled = true
      $0.darkPresetID = preset.id
    }

    #expect(model.appearanceBindings.isEnabled)
    #expect(model.appearanceBindings.darkPresetID == preset.id)
  }

  /// Deleting a preset clears any binding pointing at it. The mirror has to
  /// show that too, or the picker keeps naming a preset that is gone.
  @Test("Deleting a bound preset clears the published binding")
  func deleteClearsPublishedBinding() {
    let model = makeModelWithPresets()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    model.updateAppearanceBindings { $0.darkPresetID = preset.id }

    model.deletePreset(id: preset.id)

    #expect(model.appearanceBindings.darkPresetID == nil)
  }

  @Test("A model built on an existing store starts with its presets")
  func mirrorIsPopulatedAtInit() {
    let defaults = makeDefaults()
    PresetStore(defaults: defaults).save(
      Preset(name: "Existing", symbolName: "sun.max", entries: [:])
    )

    let model = AppModel(
      discovery: StubDiscovery(),
      gamma: GammaDimmer(),
      preferences: makePreferences(),
      presets: PresetStore(defaults: defaults),
      keyBindings: KeyBindingStore(defaults: makeDefaults())
    )

    #expect(model.presetList.map(\.name) == ["Existing"])
  }

  // MARK: - The key binding mirror

  @Test("Forgetting a taught key is published")
  func forgetUpdatesKeyBindingList() {
    let defaults = makeDefaults()
    let signature = KeySignature(usagePage: 0x0C, usage: 0x6F, vendorID: 0x05AC, productID: 0x0250)
    KeyBindingStore(defaults: defaults).bind(signature, to: .brightnessUp, keyboardName: "Test")

    let model = AppModel(
      discovery: StubDiscovery(),
      gamma: GammaDimmer(),
      preferences: makePreferences(),
      presets: PresetStore(defaults: makeDefaults()),
      keyBindings: KeyBindingStore(defaults: defaults)
    )
    #expect(model.keyBindingList.count == 1)

    model.forgetLearnedKey(signature)

    #expect(model.keyBindingList.isEmpty)
  }

  // MARK: - What rule is in force

  /// This used to be a stringified UUID nothing could see. The panel and the
  /// overview both name it now, so what it holds and when it is cleared are
  /// worth pinning down.
  ///
  /// `frontmostAppChanged(to:)` is internal for exactly these: the only other
  /// way in is a real application coming to the front.

  @Test("With no rules and no fallback, nothing is in force")
  func noRulesMeansNoActiveRule() {
    let model = makeModelWithRules()

    model.frontmostAppChanged(to: "com.apple.Safari")

    #expect(model.activeRule == nil)
  }

  @Test("A matching rule names the app and the rule it came from")
  func matchingRuleIsRecorded() {
    let model = makeModelWithRules()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    let rule = AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: preset.id)
    model.saveAppRule(rule)

    model.frontmostAppChanged(to: "com.apple.Safari")

    #expect(model.activeRule?.presetID == preset.id)
    #expect(model.activeRule?.ruleID == rule.id)
    #expect(model.activeRule?.appName == "Safari")
  }

  /// The fallback and a rule are different facts, and the interface says them
  /// differently — "Safari → Night" against "Fallback → Night". A nil `ruleID`
  /// is what tells them apart.
  @Test("The fallback is recorded with no rule behind it")
  func fallbackIsRecordedWithoutARule() {
    let model = makeModelWithRules()
    let preset = model.captureCurrentState(name: "Day", symbolName: "sun.max")
    model.setFallbackPreset(preset.id)

    model.frontmostAppChanged(to: "com.example.Unknown")

    #expect(model.activeRule?.presetID == preset.id)
    #expect(model.activeRule?.ruleID == nil)
    #expect(model.activeRule?.appName == nil)
  }

  /// Moving between two applications that share a preset still changes what is
  /// in force, because the sentence names the app and the app changed. The
  /// guard that stops the DDC writes repeating is a separate thing.
  @Test("A second app on the same preset still updates what is shown")
  func sameSourcePresetStillRenamesTheApp() {
    let model = makeModelWithRules()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    model.saveAppRule(
      AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: preset.id)
    )
    model.saveAppRule(
      AppRule(bundleIdentifier: "com.apple.Mail", name: "Mail", presetID: preset.id)
    )

    model.frontmostAppChanged(to: "com.apple.Safari")
    #expect(model.activeRule?.appName == "Safari")

    model.frontmostAppChanged(to: "com.apple.Mail")
    #expect(model.activeRule?.appName == "Mail")
  }

  @Test("Deleting the rule in force clears it")
  func deletingTheRuleClearsIt() {
    let model = makeModelWithRules()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    let rule = AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: preset.id)
    model.saveAppRule(rule)
    model.frontmostAppChanged(to: "com.apple.Safari")
    #expect(model.activeRule != nil)

    model.deleteAppRule(id: rule.id)

    #expect(model.activeRule == nil)
  }

  /// Deleting the preset takes the rule with it — `pruneMissingPresets` sees to
  /// that — so what is in force has to go too, or the panel names a preset that
  /// no longer exists.
  @Test("Deleting the preset behind the rule clears it")
  func deletingThePresetClearsIt() {
    let model = makeModelWithRules()
    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    model.saveAppRule(
      AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: preset.id)
    )
    model.frontmostAppChanged(to: "com.apple.Safari")
    #expect(model.activeRule != nil)

    model.deletePreset(id: preset.id)

    #expect(model.activeRule == nil)
  }

  /// `lastAppliedPresetID` has been recorded since presets existed and was
  /// never shown. Both new surfaces resolve it through this.
  @Test("The preset applied last resolves to the preset")
  func activePresetResolves() {
    let model = makeModelWithRules()
    #expect(model.activePreset == nil)

    let preset = model.captureCurrentState(name: "Night", symbolName: "moon")
    model.apply(preset)

    #expect(model.activePreset?.id == preset.id)
    #expect(model.activePreset?.name == "Night")
  }
}

/// A model with its own throwaway rule store as well, which the preset factory
/// above does not give out.
@MainActor
private func makeModelWithRules() -> AppModel {
  let model = AppModel(
    discovery: StubDiscovery(),
    gamma: GammaDimmer(),
    preferences: makePreferences(),
    presets: PresetStore(defaults: makeDefaults()),
    keyBindings: KeyBindingStore(defaults: makeDefaults()),
    appRules: AppRuleStore(defaults: makeDefaults())
  )
  model.refresh()
  return model
}
