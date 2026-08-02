import AppKit
import Combine
import PixelPilotCore

/// The app's only sources of "something changed".
///
/// This type exists to make a rule enforceable rather than aspirational: there
/// is no polling anywhere in Pixel Pilot. An idle menu bar app that wakes up
/// several times a second to check on things is the exact failure mode this
/// project is trying to avoid, and it is very easy to introduce by accident.
///
/// Everything reactive hangs off these three notifications:
///
/// - **Screen parameters** — a display connected, disconnected, or changed mode.
/// - **Wake** — the gamma table does not survive sleep and must be reasserted.
/// - **Colour/appearance change** — Night Shift, True Tone and profile switches
///   reset gamma out from under us.
@MainActor
final class DisplayEvents {
  private var observers: [any NSObjectProtocol] = []

  /// Coalesces the bursts of notifications macOS emits for a single physical
  /// event — plugging in one monitor can produce half a dozen.
  private let reconfiguration = Debouncer(delay: .milliseconds(400))

  var onDisplaysChanged: (() -> Void)?
  var onWake: (() -> Void)?
  var onColorSettingsChanged: (() -> Void)?
  /// Fires when the system switches between light and dark. Drives preset
  /// automation, which is why that automation costs nothing while idle.
  var onAppearanceChanged: ((_ isDark: Bool) -> Void)?
  /// Fires when the Accessibility permission list changes — someone ticking or
  /// unticking a box in System Settings.
  var onAccessibilityTrustChanged: (() -> Void)?

  private var appearanceObservation: NSKeyValueObservation?

  func start() {
    let center = NotificationCenter.default
    let workspace = NSWorkspace.shared.notificationCenter

    observers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleReconfiguration() }
    })

    observers.append(workspace.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onWake?() }
    })

    // Posted when the display colour profile changes, which includes Night
    // Shift transitions — the most common thing to silently undo our gamma.
    observers.append(DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.ColorSyncSettingsChanged"),
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onColorSettingsChanged?() }
    })

    // Posted when the Accessibility list is changed in System Settings.
    //
    // Without this, noticing a grant depended on the app being activated
    // afterwards — and this app has no Dock icon, so "switch back to Pixel
    // Pilot" is not a thing that reliably happens. Someone would tick the box,
    // look at the settings window still saying the permission was missing, and
    // reasonably conclude it had not worked.
    //
    // Event-driven, so the rule at the top of this file still holds: nothing
    // here polls, and this costs nothing until somebody opens System Settings.
    observers.append(DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.accessibility.api"),
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.accessibilityTrustChanged() }
    })

    // Observing the effective appearance rather than the "AppleInterfaceThemeChanged"
    // distributed notification: this also covers Auto mode switching at dusk,
    // and it reports the appearance the app has actually resolved to.
    appearanceObservation = NSApplication.shared.observe(
      \.effectiveAppearance, options: [.new]
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let isDark = NSApplication.shared.effectiveAppearance
          .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        self.onAppearanceChanged?(isDark)
      }
    }
  }

  /// The appearance right now, for deciding what to apply at launch.
  var isDarkAppearance: Bool {
    NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  func stop() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    observers.removeAll()
    appearanceObservation?.invalidate()
    appearanceObservation = nil

    let debouncer = reconfiguration
    Task { await debouncer.cancel() }
  }

  /// Asks twice, and that is not superstition.
  ///
  /// The notification is posted when the *list* changes, which is a moment
  /// before `AXIsProcessTrusted()` starts agreeing: the answer is resolved
  /// against a TCC database that is still being written. Checking only on
  /// arrival reads the old value and leaves the warning on screen — which is the
  /// exact fault this observer was added to fix. So it asks now, for the case
  /// where the database was already settled, and once more shortly after.
  private func accessibilityTrustChanged() {
    onAccessibilityTrustChanged?()
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      self?.onAccessibilityTrustChanged?()
    }
  }

  /// Hands the burst to the trailing-edge debouncer. Nothing stays scheduled
  /// once it fires — see `Debouncer`, where that property is tested.
  private func scheduleReconfiguration() {
    let debouncer = reconfiguration
    Task { [weak self] in
      await debouncer.trigger {
        await MainActor.run { self?.onDisplaysChanged?() }
      }
    }
  }
}
