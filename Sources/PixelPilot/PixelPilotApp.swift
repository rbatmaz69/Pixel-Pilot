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
    model.start()
    statusItem.install()
  }

  /// If the app quits while a display is dimmed via the gamma table, that
  /// display stays dark.
  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // The main window closing must not quit a menu bar app.
    false
  }
}
