import Foundation
import os

/// What a preset asks of a display's white point.
///
/// Three states rather than two, and the third is the one that is easy to leave
/// out. A `Double?` would give "leave the colour alone" and "set it to N", and
/// then a preset called "Day" could not undo a preset called "Night" — it would
/// have no way to say *turn the warmth off* as opposed to *do not touch it*.
/// The screen would simply stay warm, which is the sort of fault people work
/// around for months rather than report.
///
/// Neutral is not 6500 K. `DisplayViewModel.colorTemperatureKelvin` spells out
/// why: at neutral there is no table of ours on the display at all, so its own
/// colour profile does exactly what it was going to do. `ScheduleStop` conflates
/// the two by treating 6500 as "off" — that is not copied here, and not changed
/// there, because the stored schedules of existing installations mean it.
public enum PresetColor: Codable, Sendable, Hashable {
  /// Take our white point off this display entirely.
  case neutral
  case kelvin(Double)

  /// In the shape `DisplayViewModel.setColorTemperature` takes, where `nil`
  /// means neutral.
  public var kelvinValue: Double? {
    if case let .kelvin(value) = self { value } else { nil }
  }

  /// Builds one from that same shape, so the round trip through a view model is
  /// written once rather than at each call site.
  public init(kelvinValue: Double?) {
    self = kelvinValue.map { Self.kelvin($0) } ?? .neutral
  }
}

/// What a preset asks of a display's finish.
///
/// The same three states as `PresetColor`, for the same reason: with a
/// `ToneCurve?` there would be "leave the finish alone" and "set this curve",
/// and no way for a preset called "Work" to say *take the paper look off*. It
/// would only ever be able to swap one finish for another, and a paper finish
/// that cannot be undone by the preset that is supposed to undo it is worse
/// than one that was never offered.
public enum PresetFinish: Codable, Sendable, Hashable {
  /// Take our tone curve off this display entirely.
  case off
  case curve(ToneCurve)

  /// In the shape `DisplayViewModel.setToneCurve` takes, where `nil` means off.
  public var curveValue: ToneCurve? {
    if case let .curve(value) = self { value } else { nil }
  }

  /// Builds one from that same shape, so the round trip through a view model is
  /// written once rather than at each call site.
  public init(curveValue: ToneCurve?) {
    self = curveValue.map { Self.curve($0) } ?? .off
  }
}

/// What a preset asks of one display.
///
/// Every field is optional, and that is the design rather than laziness. A
/// preset called "Night" probably wants to lower brightness and leave contrast
/// alone; forcing it to carry a value for everything would mean it silently
/// undoes adjustments the user made for other reasons. Absent means "leave it".
/// **There is deliberately no input source here.** Switching inputs is the one
/// action that can leave the Mac with no picture, so it needs a confirmation —
/// and a preset applied by a schedule, an app rule or the system appearance has
/// nobody in front of it to ask. There used to be a field for it, carried
/// through storage and read by nothing; a preset that looks like it remembers
/// the input and silently does not is worse than one that never claimed to.
///
/// Volume is here and mute is not: zero is silence, and a second field meaning
/// the same state is somewhere for the two to disagree.
public struct PresetEntry: Codable, Sendable, Hashable {
  public var brightness: Double?
  public var contrast: Double?
  public var volume: Double?
  /// The white point, or nil to leave the colour untouched.
  ///
  /// No hand-written `init(from:)` for this, unlike everything in
  /// `Preferences`: the synthesised decoder uses `decodeIfPresent` for optional
  /// properties, so a preset written before this field existed decodes with it
  /// absent rather than throwing. That distinction is load-bearing —
  /// `PresetStore.decode` swallows a throw with `try?` and would take *every*
  /// preset with it — so it is pinned by a test rather than left to memory.
  /// The same decoder is what lets a preset written *before* this rewrite, with
  /// an `inputSource` key still in it, decode by ignoring the key.
  public var color: PresetColor?
  /// The finish, or nil to leave it untouched. Decoded by the same synthesised
  /// decoder and for the same reason as `color` above: a preset stored before
  /// this field existed has to come back with it absent rather than throw.
  public var finish: PresetFinish?

  public init(
    brightness: Double? = nil,
    contrast: Double? = nil,
    volume: Double? = nil,
    color: PresetColor? = nil,
    finish: PresetFinish? = nil
  ) {
    self.brightness = brightness
    self.contrast = contrast
    self.volume = volume
    self.color = color
    self.finish = finish
  }

  public var isEmpty: Bool {
    brightness == nil && contrast == nil && volume == nil && color == nil && finish == nil
  }
}

/// A named set of display states.
public struct Preset: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  /// An SF Symbol name, shown in the menu bar next to the preset.
  public var symbolName: String
  /// Keyed by display, so a preset follows the panel rather than the port.
  /// Displays that are not mentioned are left untouched.
  public var entries: [DisplayKey: PresetEntry]

  public init(
    id: UUID = UUID(),
    name: String,
    symbolName: String = "circle.lefthalf.filled",
    entries: [DisplayKey: PresetEntry] = [:]
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.entries = entries
  }

  public func entry(for key: DisplayKey) -> PresetEntry? {
    guard let entry = entries[key], !entry.isEmpty else { return nil }
    return entry
  }

  /// Displays this preset actually says something about.
  public var affectedDisplays: [DisplayKey] {
    entries.filter { !$0.value.isEmpty }.map(\.key)
  }

  /// Re-captures this preset from `fresh`, keeping what `fresh` says nothing
  /// about.
  ///
  /// The whole point of the merge is the display that is not plugged in right
  /// now. Someone nudging their "Evening" preset at the office must not thereby
  /// wipe what it says about the monitor at home — and if the entries were
  /// simply replaced, that is exactly what would happen, silently, to be
  /// discovered weeks later with no way back.
  ///
  /// Identity, name and symbol are untouched, so every hotkey, app rule and
  /// appearance binding pointing at this preset keeps pointing at it.
  public func updating(entries fresh: [DisplayKey: PresetEntry]) -> Preset {
    var updated = self
    for (key, entry) in fresh {
      updated.entries[key] = entry
    }
    return updated
  }
}

/// Stores presets, and which of them follow the system appearance.
///
/// Appearance binding is the free one: macOS announces light and dark as a
/// notification, so nothing has to be waiting for it.
///
/// This used to say a clock schedule was a bad trade, needing a timer and a
/// location permission. Both turned out to be avoidable — `DaySchedule` sleeps
/// once until the next stop rather than ticking, and the location is optional,
/// asked for one time and rounded to 11 km — so the schedule lives there and
/// this stays what it always was.
public final class PresetStore: @unchecked Sendable {
  public static let shared = PresetStore()

  private enum Key {
    static let presets = "presets"
    static let appearanceBindings = "presetAppearanceBindings"
  }

  /// Which preset to apply when the system switches appearance.
  public struct AppearanceBindings: Codable, Sendable, Equatable {
    public var lightPresetID: UUID?
    public var darkPresetID: UUID?
    public var isEnabled: Bool = false

    public init() {}
  }

  private let defaults: UserDefaults
  private let lock = NSLock()
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "presets")

  private var storage: [Preset]
  private var bindingsStorage: AppearanceBindings

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.storage = Self.decode([Preset].self, from: defaults, key: Key.presets) ?? []
    self.bindingsStorage = Self.decode(
      AppearanceBindings.self, from: defaults, key: Key.appearanceBindings
    ) ?? AppearanceBindings()
  }

  // MARK: - Presets

  public var presets: [Preset] {
    lock.withLock { storage }
  }

  public func preset(id: UUID) -> Preset? {
    lock.withLock { storage.first { $0.id == id } }
  }

  /// Inserts or replaces, keeping insertion order stable so the menu does not
  /// reshuffle itself when a preset is edited.
  public func save(_ preset: Preset) {
    lock.lock()
    if let index = storage.firstIndex(where: { $0.id == preset.id }) {
      storage[index] = preset
    } else {
      storage.append(preset)
    }
    let snapshot = storage
    lock.unlock()

    persist(snapshot, key: Key.presets)
  }

  public func delete(id: UUID) {
    lock.lock()
    guard let index = storage.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    storage.remove(at: index)
    let snapshot = storage
    var bindings = bindingsStorage
    lock.unlock()

    persist(snapshot, key: Key.presets)

    // A binding pointing at a deleted preset would silently do nothing on the
    // next appearance change.
    if bindings.lightPresetID == id { bindings.lightPresetID = nil }
    if bindings.darkPresetID == id { bindings.darkPresetID = nil }
    updateAppearanceBindings { $0 = bindings }
  }

  /// Reorders presets.
  ///
  /// Implemented by hand because the familiar `move(fromOffsets:toOffset:)`
  /// comes from SwiftUI, and this package deliberately has no UI dependency.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    lock.lock()
    let moved = source.map { storage[$0] }
    // Count how many removed elements sat before the target, so the insertion
    // point still means the same place after removal.
    let adjustedDestination = destination - source.filter { $0 < destination }.count
    for index in source.sorted(by: >) {
      storage.remove(at: index)
    }
    storage.insert(contentsOf: moved, at: max(0, min(adjustedDestination, storage.count)))
    let snapshot = storage
    lock.unlock()

    persist(snapshot, key: Key.presets)
  }

  // MARK: - Appearance bindings

  public var appearanceBindings: AppearanceBindings {
    lock.withLock { bindingsStorage }
  }

  public func updateAppearanceBindings(_ mutate: (inout AppearanceBindings) -> Void) {
    lock.lock()
    var bindings = bindingsStorage
    let before = bindings
    mutate(&bindings)
    guard bindings != before else {
      lock.unlock()
      return
    }
    bindingsStorage = bindings
    lock.unlock()

    persist(bindings, key: Key.appearanceBindings)
  }

  /// The preset to apply for an appearance, or nil when automatic switching is
  /// off or nothing is bound.
  public func preset(forDarkAppearance isDark: Bool) -> Preset? {
    let bindings = appearanceBindings
    guard bindings.isEnabled else { return nil }
    guard let id = isDark ? bindings.darkPresetID : bindings.lightPresetID else { return nil }
    return preset(id: id)
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
