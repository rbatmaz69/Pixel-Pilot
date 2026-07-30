import AppKit
import IOKit.hid
import os

/// Watches media keys at the HID layer, below the event tap.
///
/// The event tap only sees keys macOS has already recognised and translated
/// into system-defined events. That translation is where third-party keyboards
/// fall down: Apple's own keyboards report brightness on a vendor usage page
/// macOS knows intimately, while everyone else uses the standard consumer-page
/// codes 0x6F and 0x70 — which macOS translates inconsistently, and often not at
/// all. Volume usually survives the trip; brightness usually does not.
///
/// So this reads the consumer page directly. It runs *alongside* the event tap,
/// not instead of it — on a keyboard where both work, one press arrives twice,
/// which is what `MediaKeyDeduplicator` is for.
///
/// Needs Input Monitoring permission, separately from Accessibility.
@MainActor
final class HIDMediaKeyMonitor {
  enum Key: Equatable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case mute
  }

  struct Event {
    let key: Key
    /// The keyboard it came from, for the diagnostics view.
    let deviceName: String
  }

  var handler: ((Event) -> Void)?
  /// Called for every consumer-page press, recognised or not. Lets the settings
  /// window show what an unsupported keyboard is actually sending.
  var observer: ((_ usage: UInt32, _ deviceName: String) -> Void)?

  private var manager: IOHIDManager?
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "hidkeys")

  /// HID Consumer page usages. The two brightness ones are the whole reason
  /// this class exists.
  private enum Usage {
    static let brightnessIncrement: UInt32 = 0x6F
    static let brightnessDecrement: UInt32 = 0x70
    static let mute: UInt32 = 0xE2
    static let volumeIncrement: UInt32 = 0xE9
    static let volumeDecrement: UInt32 = 0xEA
  }

  private static func key(for usage: UInt32) -> Key? {
    switch usage {
    case Usage.brightnessIncrement: .brightnessUp
    case Usage.brightnessDecrement: .brightnessDown
    case Usage.volumeIncrement: .volumeUp
    case Usage.volumeDecrement: .volumeDown
    case Usage.mute: .mute
    default: nil
    }
  }

  // MARK: - Permission

  /// Input Monitoring, which is not the same grant as Accessibility.
  static var isTrusted: Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  }

  @discardableResult
  static func requestTrust() -> Bool {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
  }

  static func openInputMonitoringSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Lifecycle

  var isRunning: Bool { manager != nil }

  @discardableResult
  func start() -> Bool {
    guard manager == nil else { return true }
    guard Self.isTrusted else {
      logger.notice("HID media keys unavailable: Input Monitoring not granted")
      return false
    }

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    // Match anything that can carry consumer controls. Keyboards expose these
    // in a separate collection from their keys, and some devices — headsets,
    // dials — expose the collection on its own.
    let criteria: [[String: Any]] = [
      [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

    // Only consumer-page values, so ordinary typing never reaches this callback.
    IOHIDManagerSetInputValueMatchingMultiple(
      manager, [[kIOHIDElementUsagePageKey: kHIDPage_Consumer]] as CFArray
    )

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
      HIDMediaKeyMonitor.handle(value: value, context: context)
    }, context)

    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else {
      logger.error("IOHIDManagerOpen failed: \(result)")
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
      )
      return false
    }

    self.manager = manager
    logger.info("HID media key monitor running")
    return true
  }

  func stop() {
    guard let manager else { return }
    IOHIDManagerUnscheduleFromRunLoop(
      manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.manager = nil
  }

  isolated deinit {
    stop()
  }

  // MARK: - Callback

  private nonisolated static func handle(
    value: IOHIDValue, context: UnsafeMutableRawPointer?
  ) {
    guard let context else { return }
    let monitor = Unmanaged<HIDMediaKeyMonitor>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    // Consumer controls report 1 on press and 0 on release; acting on release
    // would double every press.
    guard IOHIDValueGetIntegerValue(value) == 1 else { return }

    let device = IOHIDElementGetDevice(element)
    let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
      ?? "unknown keyboard"

    MainActor.assumeIsolated {
      monitor.observer?(usage, name)
      guard let key = key(for: usage) else { return }
      monitor.handler?(Event(key: key, deviceName: name))
    }
  }
}
