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
