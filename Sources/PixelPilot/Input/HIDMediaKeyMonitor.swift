import AppKit
import IOKit.hid
import PixelPilotCore
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
///
/// **It is not free.** An open `IOHIDManager` costs about 0.33% of a core
/// continuously — measured as 0.20 s of CPU over 60 s of complete idle, against
/// 0.00 s with this class disabled and everything else running. Narrowing which
/// devices and elements are matched does not change that; the cost is in having
/// the connection open at all.
///
/// For an app whose whole premise is costing nothing while idle, that is worth a
/// switch rather than a silent default, which is why `hidMediaKeysEnabled`
/// exists. Keyboards macOS already understands work without this.
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

  /// A raw press, before any interpretation.
  struct RawPress {
    let signature: KeySignature
    let deviceName: String
  }

  var handler: ((Event) -> Void)?
  /// Called for every press the monitor sees, recognised or not. Lets the
  /// settings window show what an unsupported keyboard is actually sending, and
  /// is what the learning sheet captures.
  var observer: ((RawPress) -> Void)?

  /// While true, every usage page is matched and nothing is acted on.
  private(set) var isLearning = false

  /// Signatures the user has taught. Watched in addition to the built-in set.
  var learnedSignatures: Set<KeySignature> = []

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

  /// The built-in mapping, before anything the user taught.
  private static func key(for usage: UInt32, page: UInt32) -> Key? {
    if page == UInt32(kHIDPage_KeyboardOrKeypad) {
      // The convention on keyboards without a Mac mode.
      switch usage {
      case UInt32(kHIDUsage_KeyboardF15): return .brightnessUp
      case UInt32(kHIDUsage_KeyboardF14): return .brightnessDown
      default: return nil
      }
    }
    guard page == UInt32(kHIDPage_Consumer) else { return nil }
    switch usage {
    case Usage.brightnessIncrement: return .brightnessUp
    case Usage.brightnessDecrement: return .brightnessDown
    case Usage.volumeIncrement: return .volumeUp
    case Usage.volumeDecrement: return .volumeDown
    case Usage.mute: return .mute
    default: return nil
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

  // MARK: - What is watched

  /// Which devices are opened.
  ///
  /// Consumer-control collections in normal operation, widened to all keyboards
  /// while learning — a keyboard that puts its keys somewhere unusual still has
  /// to be reachable.
  ///
  /// The narrowing is not a performance measure, though it was tried as one:
  /// matching every keyboard versus only consumer collections made no
  /// measurable difference (0.35% against 0.33%). Having an `IOHIDManager` open
  /// at all is what costs; see `HIDMediaKeyMonitor`'s notes on that.
  private func deviceMatching() -> [[String: Any]] {
    var criteria: [[String: Any]] = [
      [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
       kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
    ]
    if isLearning {
      criteria.append([
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
      ])
    }
    return criteria
  }

  /// Which elements produce callbacks.
  ///
  /// Narrow by default and wide only while learning. Watching every page all
  /// the time would mean seeing every keystroke, which is not something an app
  /// should do to answer a question it asks once.
  private func valueMatching() -> [[String: Any]] {
    if isLearning {
      // Everything, so a key on a vendor page can be captured — the case that
      // makes this feature necessary at all.
      return [[:]]
    }

    var criteria: [[String: Any]] = [
      // The consumer page as a whole: it carries media and system controls, not
      // typed characters, and seeing unrecognised ones is what makes the
      // diagnostics useful.
      [kIOHIDElementUsagePageKey: kHIDPage_Consumer],
      // F14 and F15 are what keyboards without a Mac mode use for brightness.
      [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
       kIOHIDElementUsageKey: kHIDUsage_KeyboardF14],
      [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
       kIOHIDElementUsageKey: kHIDUsage_KeyboardF15],
    ]

    // Plus exactly the keys the user taught, and nothing else on their pages.
    for signature in learnedSignatures where signature.usagePage != UInt32(kHIDPage_Consumer) {
      criteria.append([
        kIOHIDElementUsagePageKey: Int(signature.usagePage),
        kIOHIDElementUsageKey: Int(signature.usage),
      ])
    }
    return criteria
  }

  /// Widens matching to every page and stops acting on presses.
  ///
  /// Implemented by restarting rather than by reconfiguring in place: changing
  /// the matching on a live manager is not reliably picked up, and a learning
  /// mode that silently keeps the old filter would capture nothing.
  func beginLearning() {
    guard !isLearning else { return }
    stop()
    isLearning = true
    start()
  }

  func endLearning() {
    guard isLearning else { return }
    stop()
    isLearning = false
    start()
  }

  /// Re-applies matching after the taught keys changed.
  func refreshMatching() {
    guard isRunning, !isLearning else { return }
    stop()
    start()
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

    IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatching() as CFArray)

    IOHIDManagerSetInputValueMatchingMultiple(manager, valueMatching() as CFArray)

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
    let page = IOHIDElementGetUsagePage(element)
    // Keys report 1 on press and 0 on release; acting on release would double
    // every press.
    guard IOHIDValueGetIntegerValue(value) == 1 else { return }

    let device = IOHIDElementGetDevice(element)
    let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
      ?? "unknown keyboard"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0

    let signature = KeySignature(
      usagePage: page, usage: usage, vendorID: vendor, productID: product
    )

    MainActor.assumeIsolated {
      monitor.observer?(RawPress(signature: signature, deviceName: name))
      // While learning, the press is only reported — acting on it would change
      // the brightness while the user is trying to tell us what a key is.
      guard !monitor.isLearning else { return }
      guard let key = key(for: usage, page: page) else { return }
      monitor.handler?(Event(key: key, deviceName: name))
    }
  }
}
