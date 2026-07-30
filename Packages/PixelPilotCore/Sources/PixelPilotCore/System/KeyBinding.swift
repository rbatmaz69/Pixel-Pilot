import Foundation
import os

/// What a media key should do.
public enum MediaKeyAction: String, Codable, Sendable, CaseIterable, Identifiable {
  case brightnessUp
  case brightnessDown
  case volumeUp
  case volumeDown
  case mute

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .brightnessUp: "Brightness up"
    case .brightnessDown: "Brightness down"
    case .volumeUp: "Volume up"
    case .volumeDown: "Volume down"
    case .mute: "Mute"
    }
  }

  public var symbolName: String {
    switch self {
    case .brightnessUp: "sun.max"
    case .brightnessDown: "sun.min"
    case .volumeUp: "speaker.wave.3"
    case .volumeDown: "speaker.wave.1"
    case .mute: "speaker.slash"
    }
  }
}

/// Identifies one key on one keyboard.
///
/// The keyboard is part of the identity on purpose. The same HID code means
/// different things on different keyboards, and a key taught on one should not
/// silently start acting when a different keyboard sends the same number.
public struct KeySignature: Hashable, Codable, Sendable {
  public var usagePage: UInt32
  public var usage: UInt32
  public var vendorID: Int
  public var productID: Int

  public init(usagePage: UInt32, usage: UInt32, vendorID: Int, productID: Int) {
    self.usagePage = usagePage
    self.usage = usage
    self.vendorID = vendorID
    self.productID = productID
  }

  public var description: String {
    String(format: "page 0x%02X usage 0x%02X", usagePage, usage)
  }
}

/// HID usage pages, for the few we reason about.
public enum HIDPage {
  public static let generic: UInt32 = 0x01
  public static let keyboard: UInt32 = 0x07
  public static let consumer: UInt32 = 0x0C
  /// Everything from here up is vendor-defined.
  public static let vendorStart: UInt32 = 0xFF00
}

/// Whether a key may be bound, and what the user should know about it.
///
/// Reading a key at the HID layer does not consume it — it still reaches
/// whatever is in the foreground. That is fine for a dedicated media key and
/// merely untidy for a function key, but binding a letter would mean the
/// brightness moved every time that letter was typed. Hence the three verdicts
/// rather than a yes/no.
public enum KeyBindability: Equatable, Sendable {
  case allowed
  /// Bindable, but it will also reach the frontmost app.
  case allowedWithWarning(String)
  case rejected(String)

  public var isAllowed: Bool {
    if case .rejected = self { return false }
    return true
  }
}

public enum KeyBindingRules {
  /// Keyboard-page usages that must never be bound.
  ///
  /// 0x04–0x27 are the letters and digits; 0xE0–0xE7 are the modifiers. A
  /// modifier binding would fire on every shortcut in the system.
  static func isTypingKey(page: UInt32, usage: UInt32) -> Bool {
    guard page == HIDPage.keyboard else { return false }
    return (0x04 ... 0x27).contains(usage) || (0xE0 ... 0xE7).contains(usage)
  }

  public static func bindability(page: UInt32, usage: UInt32) -> KeyBindability {
    if isTypingKey(page: page, usage: usage) {
      return .rejected(
        "That is an ordinary typing key. Binding it would change brightness every time "
          + "you typed it, because keys read this way still reach whatever you are using."
      )
    }
    if page == HIDPage.keyboard {
      return .allowedWithWarning(
        "This is a regular key, so it will still reach the app you are working in. "
          + "Fine for keys nothing else uses, awkward otherwise."
      )
    }
    if page == HIDPage.consumer || page >= HIDPage.vendorStart {
      return .allowed
    }
    return .allowedWithWarning(
      "An unusual page for a media key — it should work, but do check that nothing else "
        + "reacts to it."
    )
  }
}

/// Keys the user has taught, keyed by what was pressed and on which keyboard.
public final class KeyBindingStore: @unchecked Sendable {
  public static let shared = KeyBindingStore()

  private static let defaultsKey = "learnedKeyBindings"

  /// Stored as a flat list rather than a dictionary: `KeySignature` is a
  /// struct key, which JSON cannot express as an object key without more
  /// ceremony than this is worth.
  private struct Entry: Codable {
    var signature: KeySignature
    var action: MediaKeyAction
    /// Only for showing the user which keyboard a binding belongs to.
    var keyboardName: String
  }

  private let defaults: UserDefaults
  private let lock = NSLock()
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "keybindings")
  private var entries: [Entry]

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey),
       let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
      self.entries = decoded
    } else {
      self.entries = []
    }
  }

  public struct Binding: Identifiable, Sendable {
    public let signature: KeySignature
    public let action: MediaKeyAction
    public let keyboardName: String

    public var id: KeySignature { signature }
  }

  public var bindings: [Binding] {
    lock.withLock {
      entries.map { Binding(signature: $0.signature, action: $0.action, keyboardName: $0.keyboardName) }
    }
  }

  public func action(for signature: KeySignature) -> MediaKeyAction? {
    lock.withLock { entries.first { $0.signature == signature }?.action }
  }

  /// Teaches a key.
  ///
  /// Replaces any binding for the same key, and also any other key previously
  /// bound to this action *on the same keyboard* — teaching a new brightness-up
  /// key should move it, not end up with two.
  public func bind(_ signature: KeySignature, to action: MediaKeyAction, keyboardName: String) {
    lock.lock()
    entries.removeAll { existing in
      existing.signature == signature
        || (existing.action == action
          && existing.signature.vendorID == signature.vendorID
          && existing.signature.productID == signature.productID)
    }
    entries.append(Entry(signature: signature, action: action, keyboardName: keyboardName))
    let snapshot = entries
    lock.unlock()

    persist(snapshot)
  }

  public func unbind(_ signature: KeySignature) {
    lock.lock()
    let before = entries.count
    entries.removeAll { $0.signature == signature }
    guard entries.count != before else {
      lock.unlock()
      return
    }
    let snapshot = entries
    lock.unlock()

    persist(snapshot)
  }

  /// Every signature we need to watch for, so the monitor can narrow its
  /// matching to exactly these plus the built-in set.
  public func watchedSignatures() -> Set<KeySignature> {
    lock.withLock { Set(entries.map(\.signature)) }
  }

  private func persist(_ snapshot: [Entry]) {
    do {
      defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.defaultsKey)
    } catch {
      logger.error("Could not persist key bindings: \(error, privacy: .public)")
    }
  }
}
