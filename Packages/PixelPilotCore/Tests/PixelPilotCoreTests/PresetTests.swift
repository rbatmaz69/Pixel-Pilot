import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Presets")
struct PresetTests {
  private func makeStore() -> (PresetStore, UserDefaults) {
    let name = "dev.rb.pixelpilot.presets.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (PresetStore(defaults: defaults), defaults)
  }

  private let displayA = DisplayKey(rawValue: "4485219c2d511fb4")
  private let displayB = DisplayKey(rawValue: "aaaabbbbccccdddd")

  @Test("Presets round-trip through storage")
  func roundTrip() {
    let (store, defaults) = makeStore()
    let preset = Preset(
      name: "Night",
      symbolName: "moon.fill",
      entries: [displayA: PresetEntry(brightness: 0.2)]
    )
    store.save(preset)

    let restored = PresetStore(defaults: defaults).presets
    #expect(restored.count == 1)
    #expect(restored.first?.name == "Night")
    #expect(restored.first?.entries[displayA]?.brightness == 0.2)
  }

  /// The point of optional fields: a preset must be able to say nothing about a
  /// value, so applying it does not silently undo an unrelated adjustment.
  @Test("An omitted value stays omitted")
  func omittedValuesSurvive() {
    let (store, defaults) = makeStore()
    store.save(Preset(name: "Dim", entries: [displayA: PresetEntry(brightness: 0.3)]))

    let entry = PresetStore(defaults: defaults).presets.first?.entries[displayA]
    #expect(entry?.brightness == 0.3)
    #expect(entry?.contrast == nil)
    #expect(entry?.inputSource == nil)
  }

  @Test("An entry with nothing set is not treated as an instruction")
  func emptyEntriesAreIgnored() {
    let preset = Preset(
      name: "Empty",
      entries: [displayA: PresetEntry(), displayB: PresetEntry(contrast: 0.5)]
    )
    #expect(preset.entry(for: displayA) == nil)
    #expect(preset.entry(for: displayB) != nil)
    #expect(preset.affectedDisplays == [displayB])
  }

  /// Preferences are meant to be openable and fixable by hand, so a display key
  /// has to appear as a plain JSON object key rather than as a wrapper object or
  /// a flattened array.
  @Test("Display keys encode as readable JSON keys")
  func readableEncoding() throws {
    let preset = Preset(name: "Day", entries: [displayA: PresetEntry(brightness: 1.0)])
    let json = String(decoding: try JSONEncoder().encode(preset), as: UTF8.self)
    #expect(json.contains("\"4485219c2d511fb4\""))
    #expect(!json.contains("rawValue"))
  }

  @Test("Updating a preset replaces it rather than adding a second")
  func updateInPlace() {
    let (store, _) = makeStore()
    var preset = Preset(name: "Work")
    store.save(preset)

    preset.name = "Focus"
    store.save(preset)

    #expect(store.presets.count == 1)
    #expect(store.presets.first?.name == "Focus")
  }

  @Test("Deleting removes the preset")
  func delete() {
    let (store, _) = makeStore()
    let preset = Preset(name: "Temp")
    store.save(preset)
    store.delete(id: preset.id)
    #expect(store.presets.isEmpty)
  }

  /// A binding left pointing at a deleted preset would make the automatic
  /// switch silently do nothing.
  @Test("Deleting a bound preset clears the binding")
  func deleteClearsBinding() {
    let (store, _) = makeStore()
    let night = Preset(name: "Night")
    store.save(night)
    store.updateAppearanceBindings {
      $0.isEnabled = true
      $0.darkPresetID = night.id
    }

    store.delete(id: night.id)
    #expect(store.appearanceBindings.darkPresetID == nil)
    #expect(store.preset(forDarkAppearance: true) == nil)
  }

  @Test("Appearance lookup respects the enabled flag")
  func appearanceLookup() {
    let (store, _) = makeStore()
    let day = Preset(name: "Day")
    let night = Preset(name: "Night")
    store.save(day)
    store.save(night)

    store.updateAppearanceBindings {
      $0.lightPresetID = day.id
      $0.darkPresetID = night.id
    }
    #expect(store.preset(forDarkAppearance: true) == nil, "disabled by default")

    store.updateAppearanceBindings { $0.isEnabled = true }
    #expect(store.preset(forDarkAppearance: true)?.name == "Night")
    #expect(store.preset(forDarkAppearance: false)?.name == "Day")
  }

  @Test("Reordering keeps every preset")
  func reordering() {
    let (store, defaults) = makeStore()
    for name in ["A", "B", "C"] {
      store.save(Preset(name: name))
    }

    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(store.presets.map(\.name) == ["B", "C", "A"])

    // And it survives a reload, which is the part that actually matters.
    #expect(PresetStore(defaults: defaults).presets.map(\.name) == ["B", "C", "A"])
  }

  @Test("Order is stable across saves so the menu does not reshuffle")
  func stableOrder() {
    let (store, _) = makeStore()
    let first = Preset(name: "First")
    let second = Preset(name: "Second")
    store.save(first)
    store.save(second)

    var edited = first
    edited.name = "First (edited)"
    store.save(edited)

    #expect(store.presets.map(\.name) == ["First (edited)", "Second"])
  }
}
