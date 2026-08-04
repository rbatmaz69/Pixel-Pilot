import CoreGraphics
import Foundation
import PixelPilotCore
import Testing

@testable import PixelPilot

/// The first tests `handleHotkey` has ever had.
///
/// It went from five actions to fifteen, and three of the new ones carry state
/// that nothing else in the app carries: which preset was applied last, whether
/// the brightness group is armed, and whether warmth is on at all. Each of those
/// is a thing that can be wrong in a way the display still looks fine and the
/// next press does something surprising.
@MainActor
@Suite("Global shortcuts")
struct HotkeyTests {
  // MARK: - The actions themselves

  /// Fifteen rows in a settings window, each of which has to say what it does
  /// and be findable. The same shape as the sidebar test in the settings window.
  @Test("Every action carries a name, a symbol and a group")
  func actionsDescribeThemselves() {
    for builtin in HotkeyCenter.Action.Builtin.allCases {
      #expect(!builtin.displayName.isEmpty)
      #expect(!builtin.symbolName.isEmpty)
      #expect(!builtin.group.title.isEmpty)
      #expect(!builtin.group.symbolName.isEmpty)
    }
  }

  /// The storage keys are the raw values, so renaming a case silently loses
  /// whatever shortcut somebody had bound to it. These five predate the ten
  /// added around them and are the ones that have shortcuts in the wild.
  @Test("The original five storage keys are unchanged")
  func storageKeysAreStable() {
    let expected: [HotkeyCenter.Action.Builtin: String] = [
      .brightnessUp: "brightnessUp",
      .brightnessDown: "brightnessDown",
      .volumeUp: "volumeUp",
      .volumeDown: "volumeDown",
      .toggleMute: "toggleMute",
    ]
    for (builtin, key) in expected {
      #expect(HotkeyCenter.Action.builtin(builtin).storageKey == key)
      #expect(HotkeyCenter.Action(storageKey: key) == .builtin(builtin))
    }
  }

  @Test("Every action survives a round trip through its storage key")
  func storageKeysRoundTrip() {
    for builtin in HotkeyCenter.Action.Builtin.allCases {
      let action = HotkeyCenter.Action.builtin(builtin)
      #expect(HotkeyCenter.Action(storageKey: action.storageKey) == action)
    }
  }

  /// Every action lands in exactly one card, and no card is empty — an empty
  /// one would draw a heading with nothing under it.
  @Test("Every group has actions in it")
  func groupsArePopulated() {
    for group in HotkeyCenter.Action.Builtin.Group.allCases {
      let members = HotkeyCenter.Action.Builtin.allCases.filter { $0.group == group }
      #expect(!members.isEmpty, "\(group.title) would draw an empty card")
    }
  }

  // MARK: - Stepping through presets

  @Test("With nothing applied yet, next gives the first preset")
  func nextFromNothing() {
    let model = makeModel()
    let first = model.captureCurrentState(name: "One", symbolName: "sun.max.fill")
    _ = model.captureCurrentState(name: "Two", symbolName: "moon.fill")

    model.stepPreset(forward: true)

    #expect(model.lastAppliedPresetID == first.id)
  }

  /// Backwards from nothing is the *last*, not the first. Somebody pressing
  /// "previous" with nothing applied means "the other end", and landing on the
  /// first would make previous and next do the same thing.
  @Test("With nothing applied yet, previous gives the last preset")
  func previousFromNothing() {
    let model = makeModel()
    _ = model.captureCurrentState(name: "One", symbolName: "sun.max.fill")
    let last = model.captureCurrentState(name: "Two", symbolName: "moon.fill")

    model.stepPreset(forward: false)

    #expect(model.lastAppliedPresetID == last.id)
  }

  @Test("Stepping wraps at both ends")
  func steppingWraps() {
    let model = makeModel()
    let first = model.captureCurrentState(name: "One", symbolName: "sun.max.fill")
    let second = model.captureCurrentState(name: "Two", symbolName: "moon.fill")

    model.stepPreset(forward: true)
    model.stepPreset(forward: true)
    #expect(model.lastAppliedPresetID == second.id)

    model.stepPreset(forward: true)
    #expect(model.lastAppliedPresetID == first.id, "off the end is back to the start")

    model.stepPreset(forward: false)
    #expect(model.lastAppliedPresetID == second.id, "and backwards off the front too")
  }

  /// Applying a preset any other way has to move the mark too, or the next
  /// press carries on from somewhere nobody has been.
  @Test("Applying a preset by hand is where stepping carries on from")
  func applyingSetsTheMark() {
    let model = makeModel()
    _ = model.captureCurrentState(name: "One", symbolName: "sun.max.fill")
    let second = model.captureCurrentState(name: "Two", symbolName: "moon.fill")
    let third = model.captureCurrentState(name: "Three", symbolName: "film.fill")

    model.apply(second)
    #expect(model.lastAppliedPresetID == second.id)

    model.stepPreset(forward: true)
    #expect(model.lastAppliedPresetID == third.id)
  }

  /// The mark points into a list that can shrink underneath it.
  @Test("Deleting the preset that was applied does not strand the stepping")
  func deletingClearsTheMark() {
    let model = makeModel()
    let first = model.captureCurrentState(name: "One", symbolName: "sun.max.fill")
    _ = model.captureCurrentState(name: "Two", symbolName: "moon.fill")

    model.apply(first)
    model.deletePreset(id: first.id)
    #expect(model.lastAppliedPresetID == nil)

    // And the next press still works, from the top.
    model.stepPreset(forward: true)
    #expect(model.lastAppliedPresetID == model.presetList.first?.id)
  }

  @Test("Stepping with no presets at all does nothing")
  func steppingWithNoPresets() {
    let model = makeModel()
    model.stepPreset(forward: true)
    #expect(model.lastAppliedPresetID == nil)
  }

  // MARK: - Warmth in steps

  /// From off there is no value to add to. Starting at either end would throw
  /// the screen a long way for one press; starting at neutral makes the first
  /// press move exactly one step off the colour that is already on screen.
  @Test("From off, the first step starts at neutral")
  func warmthStartsAtNeutral() {
    let display = makeDisplayModel()
    #expect(display.colorTemperatureKelvin == nil)

    let warmed = display.adjustColorTemperature(by: -500)

    #expect(warmed == ColorTemperature.neutralKelvin - 500)
  }

  /// Neutral and 6500 K are the same picture and not the same state: at neutral
  /// there is no table of ours on the display at all. Walking the warmth back
  /// has to take the table off rather than leave one behind that does nothing.
  @Test("Landing on neutral switches the warmth off rather than storing 6500")
  func warmthReturnsToOff() {
    let display = makeDisplayModel()
    display.setColorTemperature(ColorTemperature.neutralKelvin - 500)

    let settled = display.adjustColorTemperature(by: 500)

    #expect(settled == nil)
    #expect(display.colorTemperatureKelvin == nil)
  }

  @Test("Warmth clamps at both ends of the scale")
  func warmthClamps() {
    let range = ColorTemperature.range

    let warm = makeDisplayModel()
    warm.setColorTemperature(range.lowerBound + 100)
    #expect(warm.adjustColorTemperature(by: -5000) == range.lowerBound)

    let cool = makeDisplayModel()
    cool.setColorTemperature(range.upperBound - 100)
    #expect(cool.adjustColorTemperature(by: 5000) == range.upperBound)
  }

  // MARK: - What the HUD says

  /// The one kind whose figure is not a percentage. Reading it as one would put
  /// "650000%" over a warmth slider.
  @Test("The warmth indicator reports Kelvin, and names neutral rather than numbering it")
  func warmthReadout() {
    let range = ColorTemperature.range
    let neutral = KelvinTrack.fraction(of: ColorTemperature.neutralKelvin)

    #expect(OSDKind.warmth.readout(for: neutral) == "Neutral")
    #expect(OSDKind.warmth.readout(for: 0).hasSuffix(" K"))
    #expect(OSDKind.warmth.readout(for: 0) == "\(Int(range.lowerBound)) K")
    #expect(OSDKind.brightness.readout(for: 0.5) == "50%")
    #expect(OSDKind.contrast.readout(for: 1) == "100%")
  }

  @Test("A preset indicator reports its name and wears its symbol")
  func presetReadout() {
    let kind = OSDKind.preset(name: "Evening", symbol: "moon.fill")

    #expect(kind.readout(for: 0) == "Evening")
    #expect(kind.symbol(for: 0) == "moon.fill")
    #expect(!kind.hasLevel, "there is no level behind a preset to draw a track for")
  }

  @Test("The kinds that report rather than set have no level")
  func inertKindsHaveNoLevel() {
    #expect(!OSDKind.muted.hasLevel)
    #expect(!OSDKind.unavailable(.volume).hasLevel)
    #expect(!OSDKind.unavailable(.contrast).hasLevel)
    #expect(OSDKind.brightness.hasLevel)
    #expect(OSDKind.warmth.hasLevel)
  }

  /// The two unavailable indicators must not look alike — one is about sound
  /// and one about a picture, and a single glyph for both would answer "which
  /// key did I just press" with a shrug.
  @Test("The two dead ends are told apart")
  func unavailableKindsDiffer() {
    #expect(OSDKind.unavailable(.volume).symbol(for: 0)
      != OSDKind.unavailable(.contrast).symbol(for: 0))
    #expect(OSDKind.unavailable(.volume).accessibilityLabel
      != OSDKind.unavailable(.contrast).accessibilityLabel)
  }

  // MARK: - Helpers

  private func makeModel() -> AppModel {
    let name = "dev.rb.pixelpilot.hotkeytests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let model = AppModel(
      discovery: EmptyDiscovery(),
      gamma: GammaDimmer(),
      preferences: Preferences(defaults: defaults),
      presets: PresetStore(defaults: defaults),
      keyBindings: KeyBindingStore(defaults: defaults)
    )
    model.refresh()
    return model
  }

  private func makeDisplayModel() -> DisplayViewModel {
    let name = "dev.rb.pixelpilot.hotkeytests.display.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return DisplayViewModel(
      display: DiscoveredDisplay(
        displayID: 1, key: DisplayKey(rawValue: "warmth"), name: "Probe", isBuiltin: false
      ),
      preferences: Preferences(defaults: defaults),
      log: DiagnosticsLog()
    )
  }
}

private final class EmptyDiscovery: DisplayDiscovering, @unchecked Sendable {
  func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay] { [] }
}
