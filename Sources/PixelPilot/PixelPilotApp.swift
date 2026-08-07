import AppKit
import PixelPilotCore
import SwiftUI
import UserNotifications

/// The entry point.
///
/// AppKit's lifecycle rather than SwiftUI's `App`, and the reason is the menu
/// bar. The panel is a hand-built `NSPanel` so it can take scroll events over
/// the status item and draw its own level gauge, and once it is not a
/// `MenuBarExtra` there is no scene that is eagerly instantiated — `Window` and
/// `Settings` are both lazy — so `openWindow` and `SettingsLink` have nothing
/// to bind to. `WindowCoordinator` explains that in full.
///
/// Every surface is still SwiftUI. Only the shell around them is not.
@main
@MainActor
final class PixelPilotMain: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private lazy var windows = WindowCoordinator(model: model)
  private lazy var statusItem = StatusItemController(model: model, windows: windows)
  private let updateNotifier = UpdateNotifier()

  static func main() {
    let application = NSApplication.shared
    let delegate = PixelPilotMain()
    application.delegate = delegate
    // Held for the process's lifetime; `NSApplication.delegate` is weak.
    Self.retained = delegate
    application.run()
  }

  private static var retained: PixelPilotMain?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Built once, up front, rather than when the first window opens. The menu
    // bar only ever appears while the app is `.regular`, and an app that builds
    // its menu at the moment it switches has a frame in which it is regular
    // with nothing in the strip.
    NSApp.mainMenu = MainMenu.make(
      appName: "Pixel Pilot",
      settingsAction: (target: self, selector: #selector(openSettings))
    )

    model.start()
    statusItem.install()
    // After the status item exists, so the introduction can point at an icon
    // that is actually in the menu bar while it is being talked about.
    windows.showOnboardingIfNeeded()

    startUpdates()
  }

  // MARK: - Updates

  /// Cleans up after an update that has just landed, then looks for the next.
  private func startUpdates() {
    // The process that installed the update could not unmount its own disk
    // image: it had to leave it mounted for `ditto` and then exit. This build
    // is the first thing that can tidy up after it.
    Updater.detachStaleMounts()

    UNUserNotificationCenter.current().delegate = self
    model.updater.onUpdateFound = { [weak self] release, version in
      self?.updateNotifier.announce(release, version: version)
    }

    // Landing on the Keys page is the whole reason the previous version was
    // recorded. The app has just come back with a different code signature, so
    // the Accessibility grant is gone and the brightness keys have stopped —
    // and every second before that is explained is a second the app looks
    // broken to somebody who did nothing wrong.
    if let previous = model.updater.justUpdatedFrom {
      model.updater.acknowledgeUpdate()
      windows.showSettings(route: .app(.keys))
      model.log.record(.info("updated from \(previous) to \(Updater.currentVersionString)"))
    }

    // Detached and after the launch path, never in it. `check()` is a no-op if
    // automatic checks are off or if GitHub was already asked today.
    Task { [model] in
      try? await Task.sleep(for: .seconds(3))
      model.updater.check()
    }
  }

  /// If the app quits while a display is dimmed via the gamma table, that
  /// display stays dark.
  func applicationWillTerminate(_ notification: Notification) {
    // Before `stop()`, because quitting closes every window and the onboarding
    // window records having been seen when it closes. Quitting the app is not
    // the same as having read it — see `WindowCoordinator.isQuitting`.
    windows.isQuitting = true
    model.stop()
  }

  @objc private func openSettings() {
    windows.showSettings()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // The main window closing must not quit a menu bar app.
    false
  }
}

/// Tapping the update notification opens the page it is about.
///
/// A notification that only says a thing exists, with no way to reach it, is
/// worse than none — it makes the user go looking for a page they have never
/// opened, in an app with no Dock icon.
extension PixelPilotMain: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run {
      windows.showSettings(route: .app(.updates))
    }
  }

  /// Shown even while the app is frontmost. This app is almost never the active
  /// one, and suppressing the banner in the rare case it is would mean the
  /// notification quietly not appearing for the person sitting in Settings.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
}
