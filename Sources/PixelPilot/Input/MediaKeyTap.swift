import AppKit
import CoreGraphics
import os

/// Intercepts the keyboard's brightness and volume keys.
///
/// macOS delivers these as `NSSystemDefined` events rather than key presses, so
/// they can only be seen with a `CGEventTap` — which needs Accessibility
/// permission. There is no sanctioned API for this; every app in this category
/// works the same way.
///
/// The consume decision is the delicate part. Swallowing a key the app cannot
/// act on breaks the built-in display's brightness for as long as the app runs,
/// which users experience as their Mac being broken rather than as this app
/// misbehaving. So the handler returns a Bool and anything it declines is passed
/// straight through.
@MainActor
final class MediaKeyTap {
  enum Key: Equatable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case mute
  }

  struct Event {
    let key: Key
    let isRepeat: Bool
    /// Shift+Option is the macOS convention for quarter-steps.
    let isFineAdjustment: Bool
  }

  /// Return true to consume the event, false to let the system handle it.
  var handler: ((Event) -> Bool)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "mediakeys")

  // MARK: - Permission

  static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Shows the system prompt. Returns the trust state as it was *before* the
  /// user answered — granting Accessibility restarts the app's TCC state, so
  /// the result is never immediately true.
  @discardableResult
  static func requestTrust() -> Bool {
    // The `kAXTrustedCheckOptionPrompt` global is a mutable CFString and so is
    // not concurrency-safe to reference; its value is this fixed key.
    let options = ["AXTrustedCheckOptionPrompt": true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  static func openAccessibilitySettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Lifecycle

  var isRunning: Bool { eventTap != nil }

  @discardableResult
  func start() -> Bool {
    guard eventTap == nil else { return true }
    guard Self.isTrusted else {
      logger.notice("Media keys unavailable: Accessibility permission not granted")
      return false
    }

    let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()

    guard let tap = CGEvent.tapCreate(
      tap: .cgAnnotatedSessionEventTap,
      place: .headInsertEventTap,
      // .defaultTap rather than .listenOnly: we need the ability to consume.
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { proxy, type, event, refcon in
        MediaKeyTap.handle(proxy: proxy, type: type, event: event, refcon: refcon)
      },
      userInfo: context
    ) else {
      logger.error("Could not create the event tap despite being trusted")
      return false
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    eventTap = tap
    runLoopSource = source
    logger.info("Media key tap running")
    return true
  }

  func stop() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
  }

  /// Isolated so it can touch the main-actor state it has to clean up. Leaving
  /// a live tap installed after this object goes away would keep intercepting
  /// the keyboard with nothing left to handle it.
  isolated deinit {
    stop()
  }

  // MARK: - Callback

  /// Runs on the main run loop, synchronously, inside the window server's
  /// dispatch of the event. It must stay cheap: the tap gets disabled if it
  /// takes too long, and the whole keyboard stalls behind it in the meantime.
  private nonisolated static func handle(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
  ) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables a tap that ever runs too long, and does not re-enable it.
    // Without this the media keys silently stop working after a hitch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      MainActor.assumeIsolated {
        tap.logger.notice("Event tap was disabled (\(type.rawValue, privacy: .public)); re-enabling")
        if let port = tap.eventTap {
          CGEvent.tapEnable(tap: port, enable: true)
        }
      }
      return nil
    }

    guard type == systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == auxControlButtonsSubtype
    else {
      return Unmanaged.passUnretained(event)
    }

    // data1 packs the key code in the high half and state flags in the low half.
    let data = nsEvent.data1
    let keyCode = Int32((data & 0xFFFF_0000) >> 16)
    let keyFlags = data & 0x0000_FFFF
    let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
    let isRepeat = (keyFlags & 0x1) == 1

    guard isKeyDown else {
      // Key-up for a key we consumed on the way down must be consumed too,
      // otherwise the system sees an unmatched release.
      return mapped(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
    }

    guard let key = mapped(keyCode) else {
      return Unmanaged.passUnretained(event)
    }

    let modifiers = nsEvent.modifierFlags
    let isFine = modifiers.contains(.shift) && modifiers.contains(.option)

    let consumed = MainActor.assumeIsolated {
      tap.handler?(Event(key: key, isRepeat: isRepeat, isFineAdjustment: isFine)) ?? false
    }

    return consumed ? nil : Unmanaged.passUnretained(event)
  }

  private nonisolated static func mapped(_ keyCode: Int32) -> Key? {
    switch keyCode {
    case NXKeyCode.brightnessUp: .brightnessUp
    case NXKeyCode.brightnessDown: .brightnessDown
    case NXKeyCode.soundUp: .volumeUp
    case NXKeyCode.soundDown: .volumeDown
    case NXKeyCode.mute: .mute
    default: nil
    }
  }
}

// These live outside the main-actor class so the event tap callback, which is
// nonisolated by necessity, can read them.

/// NX_KEYTYPE_* constants from IOKit's ev_keymap.h, which has no Swift overlay.
private enum NXKeyCode {
  static let soundUp: Int32 = 0
  static let soundDown: Int32 = 1
  static let brightnessUp: Int32 = 2
  static let brightnessDown: Int32 = 3
  static let mute: Int32 = 7
}

/// `NSEvent.EventType.systemDefined` has no `CGEventType` counterpart in the
/// Swift overlay, but the raw values are the same namespace.
private let systemDefinedEventType = CGEventType(
  rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)
)!

/// The `NSEvent` subtype carrying auxiliary control buttons (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
private let auxControlButtonsSubtype: Int16 = 8
