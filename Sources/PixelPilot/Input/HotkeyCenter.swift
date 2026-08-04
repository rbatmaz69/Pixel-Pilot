import AppKit
import Carbon.HIToolbox
import os

/// A keyboard shortcut, in the form Carbon wants it.
struct Shortcut: Codable, Hashable, Sendable {
  /// Virtual key code (`kVK_*`), not a character — layout independent.
  var keyCode: UInt32
  /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
  var carbonModifiers: UInt32

  init(keyCode: UInt32, carbonModifiers: UInt32) {
    self.keyCode = keyCode
    self.carbonModifiers = carbonModifiers
  }

  init?(event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

    // A shortcut with no modifier would swallow an ordinary keystroke system
    // wide. Function keys are the one safe exception.
    let isFunctionKey = flags.contains(.function)
    guard carbon != 0 || isFunctionKey else { return nil }

    self.keyCode = UInt32(event.keyCode)
    self.carbonModifiers = carbon
  }

  var modifierFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    return flags
  }

  /// Human-readable form, e.g. `⌃⌥F1`.
  var displayString: String {
    var text = ""
    if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
    if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
    if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
    if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
    return text + KeyCodeNames.name(for: keyCode)
  }
}

/// System-wide keyboard shortcuts.
///
/// Carbon's `RegisterEventHotKey` is used rather than a second `CGEventTap`.
/// It is old, but it needs no Accessibility permission, it cannot stall the
/// keyboard the way a slow tap can, and the system resolves conflicts with
/// existing shortcuts for us instead of us silently stealing them.
@MainActor
final class HotkeyCenter {
  /// What a shortcut does.
  ///
  /// Presets are created at runtime, so this cannot stay a fixed enum. The
  /// string encoding is chosen so that shortcuts stored under the previous
  /// fixed-case version still load: a built-in action keeps exactly the raw
  /// value it had before, and only presets use the namespaced form.
  enum Action: Hashable, Identifiable {
    case builtin(Builtin)
    case preset(UUID)

    /// Everything a shortcut can do that is not "apply that preset".
    ///
    /// The raw values of the first five are load-bearing: they are the storage
    /// keys, and changing one takes the shortcut with it. New cases are free to
    /// be added — `HotkeyStore` drops keys it does not recognise one at a time
    /// rather than refusing the whole file — but none of these five may be
    /// renamed.
    enum Builtin: String, CaseIterable, Sendable {
      case brightnessUp
      case brightnessDown
      case volumeUp
      case volumeDown
      case toggleMute
      case allBrightnessUp
      case allBrightnessDown
      case contrastUp
      case contrastDown
      case warmer
      case cooler
      case nextPreset
      case previousPreset
      case identifyDisplays
      case openPanel

      var displayName: String {
        switch self {
        case .brightnessUp: "Increase brightness"
        case .brightnessDown: "Decrease brightness"
        case .allBrightnessUp: "Increase brightness everywhere"
        case .allBrightnessDown: "Decrease brightness everywhere"
        case .contrastUp: "Increase contrast"
        case .contrastDown: "Decrease contrast"
        case .warmer: "Warmer"
        case .cooler: "Cooler"
        case .volumeUp: "Increase volume"
        case .volumeDown: "Decrease volume"
        case .toggleMute: "Toggle mute"
        case .nextPreset: "Next preset"
        case .previousPreset: "Previous preset"
        case .identifyDisplays: "Identify displays"
        case .openPanel: "Open the menu bar panel"
        }
      }

      /// The glyph beside the name.
      ///
      /// There was none, and the settings page drew a command symbol on every
      /// row — fine for five rows, useless for fifteen. `MediaKeyAction` in the
      /// core carries one for the same reason, and where the two describe the
      /// same key they use the same glyph.
      var symbolName: String {
        switch self {
        case .brightnessUp, .allBrightnessUp: "sun.max"
        case .brightnessDown, .allBrightnessDown: "sun.min"
        case .contrastUp, .contrastDown: "circle.lefthalf.filled"
        case .warmer: "thermometer.sun"
        case .cooler: "snowflake"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .toggleMute: "speaker.slash"
        case .nextPreset: "chevron.forward.circle"
        case .previousPreset: "chevron.backward.circle"
        case .identifyDisplays: "number.circle"
        case .openPanel: "menubar.arrow.down.rectangle"
        }
      }

      /// Which card this row belongs in.
      ///
      /// Fifteen rows in one list is a list nobody reads to the end of. The
      /// split is by what the shortcut acts on, which is also how somebody
      /// looking for one would think about it.
      var group: Group {
        switch self {
        case .brightnessUp, .brightnessDown, .allBrightnessUp, .allBrightnessDown,
             .contrastUp, .contrastDown, .warmer, .cooler:
          .displays
        case .volumeUp, .volumeDown, .toggleMute:
          .sound
        case .nextPreset, .previousPreset:
          .presets
        case .identifyDisplays, .openPanel:
          .app
        }
      }

      enum Group: String, CaseIterable, Sendable {
        case displays, sound, presets, app

        var title: String {
          switch self {
          case .displays: "Displays"
          case .sound: "Sound"
          case .presets: "Presets"
          case .app: "Pixel Pilot"
          }
        }

        var symbolName: String {
          switch self {
          case .displays: "display"
          case .sound: "speaker.wave.2"
          case .presets: "square.stack"
          case .app: "command"
          }
        }
      }
    }

    private static let presetPrefix = "preset:"

    var storageKey: String {
      switch self {
      case let .builtin(builtin): builtin.rawValue
      case let .preset(id): Self.presetPrefix + id.uuidString
      }
    }

    init?(storageKey: String) {
      if storageKey.hasPrefix(Self.presetPrefix) {
        let raw = String(storageKey.dropFirst(Self.presetPrefix.count))
        guard let id = UUID(uuidString: raw) else { return nil }
        self = .preset(id)
      } else if let builtin = Builtin(rawValue: storageKey) {
        self = .builtin(builtin)
      } else {
        return nil
      }
    }

    var id: String { storageKey }

    /// Presets are named by the user, so their label has to be looked up rather
    /// than derived.
    var builtinDisplayName: String? {
      if case let .builtin(builtin) = self { return builtin.displayName }
      return nil
    }
  }

  var handler: ((Action) -> Void)?

  private var registrations: [UInt32: (action: Action, ref: EventHotKeyRef)] = [:]
  private var nextID: UInt32 = 1
  private var eventHandler: EventHandlerRef?
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "hotkeys")

  /// Nonisolated so the Carbon dispatch callback, which cannot be main-actor
  /// isolated, can check it.
  private nonisolated static let signature: OSType = 0x5050_4C54 // 'PPLT'

  // MARK: - Lifecycle

  func start() {
    guard eventHandler == nil else { return }

    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()

    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData in
        HotkeyCenter.dispatch(event: event, userData: userData)
      },
      1,
      &spec,
      context,
      &eventHandler
    )
  }

  func stop() {
    unregisterAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
    eventHandler = nil
  }

  isolated deinit {
    stop()
  }

  // MARK: - Registration

  /// Replaces whatever was registered before. Returns false when the system
  /// refuses — almost always because another app already owns the combination.
  @discardableResult
  func register(_ shortcut: Shortcut, for action: Action) -> Bool {
    unregister(action)

    let id = nextID
    nextID += 1

    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &ref
    )

    guard status == noErr, let ref else {
      logger.notice("Could not register \(shortcut.displayString, privacy: .public) (status \(status))")
      return false
    }

    registrations[id] = (action, ref)
    return true
  }

  func unregister(_ action: Action) {
    for (id, registration) in registrations where registration.action == action {
      UnregisterEventHotKey(registration.ref)
      registrations.removeValue(forKey: id)
    }
  }

  func unregisterAll() {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.ref)
    }
    registrations.removeAll()
  }

  // MARK: - Dispatch

  private nonisolated static func dispatch(
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == signature else {
      return OSStatus(eventNotHandledErr)
    }

    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
      guard let action = center.registrations[hotKeyID.id]?.action else {
        return OSStatus(eventNotHandledErr)
      }
      center.handler?(action)
      return noErr
    }
  }
}

/// Virtual key code to display name.
///
/// Only the keys that cannot be derived from the current layout are listed;
/// everything else is resolved through the keyboard layout so a shortcut shows
/// the character actually printed on the user's key.
enum KeyCodeNames {
  private static let special: [UInt32: String] = [
    UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
    UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
    UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
    UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
    UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
    UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
    UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
    UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
    UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
  ]

  static func name(for keyCode: UInt32) -> String {
    if let special = special[keyCode] { return special }
    if let character = layoutCharacter(for: keyCode) { return character.uppercased() }
    return "Key \(keyCode)"
  }

  /// Asks the active keyboard layout what this key produces, so a German
  /// keyboard shows Z where a US one shows Y.
  private static func layoutCharacter(for keyCode: UInt32) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }

    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    return data.withUnsafeBytes { buffer -> String? in
      guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
        return nil
      }
      var deadKeyState: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)

      let status = UCKeyTranslate(
        layout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0, // no modifiers: we want the base character
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        characters.count,
        &length,
        &characters
      )
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length)
    }
  }
}
