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
  private var pendingReconfiguration: Task<Void, Never>?

  var onDisplaysChanged: (() -> Void)?
  var onWake: (() -> Void)?
  var onColorSettingsChanged: (() -> Void)?

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
  }

  func stop() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    observers.removeAll()
    pendingReconfiguration?.cancel()
    pendingReconfiguration = nil
  }

  deinit {
    pendingReconfiguration?.cancel()
  }

  /// Debounces to the trailing edge. This is a short-lived task created in
  /// response to a real event, not a recurring timer — it exists for a few
  /// hundred milliseconds and then the app is quiescent again.
  private func scheduleReconfiguration() {
    pendingReconfiguration?.cancel()
    pendingReconfiguration = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.pendingReconfiguration = nil
      self?.onDisplaysChanged?()
    }
  }
}
