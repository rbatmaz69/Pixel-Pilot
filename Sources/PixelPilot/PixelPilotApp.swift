import AppKit
import PixelPilotCore
import SwiftUI

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
