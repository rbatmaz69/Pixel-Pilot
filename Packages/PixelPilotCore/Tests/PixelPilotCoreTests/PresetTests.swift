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
    #expect(entry?.volume == nil)
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

  // MARK: - Colour

  /// The distinction the whole enum exists for. Collapsing these two would make
  /// a "Day" preset unable to undo a "Night" one.
  @Test("Neutral is not 6500 K")
  func neutralIsNotSixThousandFiveHundred() {
    #expect(PresetColor.neutral != PresetColor.kelvin(6500))
    #expect(PresetColor.neutral.kelvinValue == nil)
    #expect(PresetColor.kelvin(3200).kelvinValue == 3200)
    // And the trip back through the shape a view model deals in.
    #expect(PresetColor(kelvinValue: nil) == .neutral)
    #expect(PresetColor(kelvinValue: 3200) == .kelvin(3200))
  }

  @Test("Both colour states survive storage")
  func colorRoundTrips() {
    let (store, defaults) = makeStore()
    store.save(Preset(name: "Night", entries: [displayA: PresetEntry(color: .kelvin(3200))]))
    store.save(Preset(name: "Day", entries: [displayA: PresetEntry(color: .neutral)]))

    let restored = PresetStore(defaults: defaults).presets
    #expect(restored.first { $0.name == "Night" }?.entries[displayA]?.color == .kelvin(3200))
    #expect(restored.first { $0.name == "Day" }?.entries[displayA]?.color == .neutral)
  }

  /// Without this, `entry(for:)` would discard a colour-only entry as empty and
  /// the preset would apply nothing at all.
  @Test("An entry carrying only a colour is still an instruction")
  func colorOnlyEntryIsNotEmpty() {
    let entry = PresetEntry(color: .neutral)
    #expect(!entry.isEmpty)

    let preset = Preset(name: "Day", entries: [displayA: entry])
    #expect(preset.entry(for: displayA) != nil)
    #expect(preset.affectedDisplays == [displayA])
  }

  /// `PresetStore.decode` swallows a throw with `try?`, so a decoding failure
  /// here does not lose one field — it loses every preset the user has.
  @Test("A preset written before colour existed still decodes, and keeps its values")
  func oldPresetsDecodeWithoutColour() throws {
    let stored = """
    [{"id":"\(UUID().uuidString)","name":"Evening","symbolName":"moon.fill",
      "entries":{"4485219c2d511fb4":{"brightness":0.3,"contrast":0.5}}}]
    """
    let presets = try JSONDecoder().decode([Preset].self, from: Data(stored.utf8))

    #expect(presets.count == 1)
    let entry = try #require(presets.first?.entries[displayA])
    #expect(entry.brightness == 0.3)
    #expect(entry.contrast == 0.5)
    #expect(entry.color == nil, "absent must mean 'leave the colour alone'")
    #expect(entry.volume == nil, "and absent must mean 'leave the volume alone'")
    #expect(entry.finish == nil, "and absent must mean 'leave the finish alone'")
  }

  // MARK: - Finish

  /// The same three states as `PresetColor`, and for the same reason: without
  /// `.off` a preset could only swap one finish for another, never take it off.
  @Test("Off is not a flat curve")
  func offIsNotAFlatCurve() {
    #expect(PresetFinish.off != PresetFinish.curve(.identity))
    #expect(PresetFinish.off.curveValue == nil)
    #expect(PresetFinish.curve(.matte).curveValue == .matte)
    #expect(PresetFinish(curveValue: nil) == .off)
    #expect(PresetFinish(curveValue: .matte) == .curve(.matte))
  }

  @Test("Both finish states survive storage")
  func finishRoundTrips() {
    let (store, defaults) = makeStore()
    store.save(Preset(name: "Read", entries: [displayA: PresetEntry(finish: .curve(.paper))]))
    store.save(Preset(name: "Work", entries: [displayA: PresetEntry(finish: .off)]))

    let restored = PresetStore(defaults: defaults).presets
    #expect(restored.first { $0.name == "Read" }?.entries[displayA]?.finish == .curve(.paper))
    #expect(restored.first { $0.name == "Work" }?.entries[displayA]?.finish == .off)
  }

  /// Without this, `entry(for:)` discards a finish-only entry as empty and the
  /// preset applies nothing at all.
  @Test("An entry carrying only a finish is still an instruction")
  func finishOnlyEntryIsNotEmpty() {
    let entry = PresetEntry(finish: .off)
    #expect(!entry.isEmpty)

    let preset = Preset(name: "Work", entries: [displayA: entry])
    #expect(preset.entry(for: displayA) != nil)
    #expect(preset.affectedDisplays == [displayA])
  }

  /// The merge is what keeps a preset's word about a monitor that is not
  /// plugged in right now — the finish has to travel with the rest of it.
  @Test("Re-capturing keeps the finish for a display that is not present")
  func recaptureKeepsAbsentDisplaysFinish() {
    let preset = Preset(name: "Read", entries: [displayB: PresetEntry(finish: .curve(.ink))])
    let updated = preset.updating(entries: [displayA: PresetEntry(brightness: 0.5)])

    #expect(updated.entries[displayB]?.finish == .curve(.ink))
    #expect(updated.entries[displayA]?.brightness == 0.5)
  }

  /// `inputSource` was carried through storage and read by nothing, so it was
  /// removed. Every preset anyone has stored still has the key in it, and the
  /// synthesised decoder ignoring an unknown key is the only reason removing it
  /// was safe — which makes that worth a test rather than an assumption.
  @Test("A preset still carrying the removed input source decodes rather than throwing")
  func oldPresetsDecodeWithInputSource() throws {
    let stored = """
    [{"id":"\(UUID().uuidString)","name":"Console","symbolName":"gamecontroller.fill",
      "entries":{"4485219c2d511fb4":{"brightness":0.8,"inputSource":17}}}]
    """
    let presets = try JSONDecoder().decode([Preset].self, from: Data(stored.utf8))

    let entry = try #require(presets.first?.entries[displayA])
    #expect(entry.brightness == 0.8)
  }

  @Test("Volume survives storage")
  func volumeRoundTrips() throws {
    let preset = Preset(name: "Film", entries: [displayA: PresetEntry(volume: 0.4)])
    let decoded = try JSONDecoder().decode(
      Preset.self, from: try JSONEncoder().encode(preset)
    )

    #expect(decoded.entries[displayA]?.volume == 0.4)
    #expect(decoded.entry(for: displayA) != nil, "a volume alone is still an instruction")
  }

  // MARK: - Re-capturing

  /// The reason the merge exists rather than a straight replacement: nudging a
  /// preset at the office must not wipe what it says about the monitor at home.
  @Test("Re-capturing leaves displays that are not present alone")
  func recaptureKeepsAbsentDisplays() {
    let preset = Preset(
      name: "Evening",
      entries: [
        displayA: PresetEntry(brightness: 0.3),
        displayB: PresetEntry(brightness: 0.6, color: .kelvin(4500)),
      ]
    )

    // Only displayA is plugged in now.
    let updated = preset.updating(entries: [displayA: PresetEntry(brightness: 0.45)])

    #expect(updated.entries[displayA]?.brightness == 0.45)
    #expect(updated.entries[displayB]?.brightness == 0.6)
    #expect(updated.entries[displayB]?.color == .kelvin(4500))
  }

  @Test("Re-capturing keeps identity, name and symbol so bindings survive")
  func recaptureKeepsIdentity() {
    let preset = Preset(name: "Evening", symbolName: "moon.fill")
    let updated = preset.updating(entries: [displayA: PresetEntry(brightness: 0.4)])

    #expect(updated.id == preset.id)
    #expect(updated.name == "Evening")
    #expect(updated.symbolName == "moon.fill")
  }

  @Test("A display seen for the first time is added by re-capturing")
  func recaptureAddsNewDisplays() {
    let preset = Preset(name: "Evening", entries: [displayA: PresetEntry(brightness: 0.3)])
    let updated = preset.updating(entries: [displayB: PresetEntry(brightness: 0.7)])

    #expect(updated.entries[displayA]?.brightness == 0.3)
    #expect(updated.entries[displayB]?.brightness == 0.7)
  }
}
