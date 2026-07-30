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

  /// Attempts to start, whether or not permission has been granted yet.
  ///
  /// The attempt is deliberate. macOS only lists an app under Input Monitoring
  /// once it has actually tried to listen — an earlier version checked
  /// `isTrusted` first and returned, so the app never asked, never appeared in
  /// the list, and could not be granted anything. The failed open is what puts
  /// it there.
  @discardableResult
  func start() -> Bool {
    guard manager == nil else { return true }

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
      // Expected until permission is granted. Asking here rather than only from
      // the settings button means the app registers itself on first launch, so
      // there is something to switch on when the user goes looking.
      if !Self.isTrusted {
        logger.notice("Input Monitoring not granted yet — requesting")
        _ = Self.requestTrust()
      } else {
        logger.error("IOHIDManagerOpen failed despite permission: \(result)")
      }
      IOHIDManagerUnscheduleFromRunLoop(
        manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
      )
      return false
    }

    self.manager = manager
    attachedDevices = Self.deviceNames(of: manager)
    logger.info("HID media key monitor running, watching \(self.attachedDevices.count) device(s)")
    return true
  }

  /// Names of the devices actually being watched.
  ///
  /// Surfaced because it splits the two ways this can fail. A keyboard missing
  /// from this list was never matched; a keyboard present in it that produces
  /// no events is sending its keys somewhere other than the consumer page.
  /// Without the distinction, "nothing happens" is unfixable.
  private(set) var attachedDevices: [String] = []

  private static func deviceNames(of manager: IOHIDManager) -> [String] {
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return devices
      .compactMap { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String }
      .sorted()
  }

  func stop() {
    guard let manager else { return }
    IOHIDManagerUnscheduleFromRunLoop(
      manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.manager = nil
    attachedDevices = []
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
