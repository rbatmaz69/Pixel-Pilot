import PixelPilotCore
import SwiftUI

enum WindowID {
  static let main = "main"
}

@main
struct PixelPilotApp: App {
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarPanel(model: model)
    } label: {
      // A template image so macOS handles light, dark and tinted menu bars.
      Image(systemName: "sun.max")
    }
    // .window rather than .menu: a menu cannot host sliders that drag.
    .menuBarExtraStyle(.window)

    // Not `WindowGroup`: exactly one settings window, opened on demand and
    // never at launch.
    Window("Displays", id: WindowID.main) {
      MainWindow(model: model)
        .withMotionTokens()
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 720, height: 480)

    Settings {
      SettingsView(model: model)
    }
  }

  init() {
    model.start()
    AppDelegate.shared = model
  }
}

/// Exists for one reason: `applicationWillTerminate`.
///
/// If the app quits while a display is dimmed via the gamma table, that display
/// stays dark. SwiftUI's `Scene` lifecycle has no reliable hook for this, so
/// AppKit's does the job.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor static var shared: AppModel?

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      Self.shared?.stop()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // The main window closing must not quit a menu bar app.
    false
  }
}
