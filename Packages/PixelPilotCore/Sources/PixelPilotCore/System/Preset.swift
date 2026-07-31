import Foundation
import os

/// What a preset asks of one display.
///
/// Every field is optional, and that is the design rather than laziness. A
/// preset called "Night" probably wants to lower brightness and leave contrast
/// alone; forcing it to carry a value for everything would mean it silently
/// undoes adjustments the user made for other reasons. Absent means "leave it".
public struct PresetEntry: Codable, Sendable, Hashable {
  public var brightness: Double?
  public var contrast: Double?
  /// A VCP 0x60 value. Only ever set from values the display declared.
  public var inputSource: UInt8?

  public init(brightness: Double? = nil, contrast: Double? = nil, inputSource: UInt8? = nil) {
    self.brightness = brightness
    self.contrast = contrast
    self.inputSource = inputSource
  }

  public var isEmpty: Bool {
    brightness == nil && contrast == nil && inputSource == nil
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
