import AppKit
import PixelPilotCore
import SwiftUI

/// Owns the app's windows.
///
/// This exists because the menu bar panel stopped being a `MenuBarExtra`. Once
/// the panel is an `NSHostingView` inside a panel AppKit made, it is outside
/// the scene graph, and `openWindow` and `SettingsLink` — both scene-graph
/// facilities — stop working. Worse, with no `MenuBarExtra` there is no
/// eagerly-instantiated scene at all (`Window` and `Settings` are both lazy),
/// so there is no live SwiftUI view anywhere at launch from which to capture an
/// `openWindow` action and stash it. Keeping a vestigial `Settings` scene alive
/// purely so `SettingsLink` would compile is the worse structure.
///
/// What is lost is SwiftUI's window restoration and the standard ⌘, menu item.
/// Neither means anything in an app with `LSUIElement: true`, no menu bar and
/// no Dock icon.
///
/// What is gained is the same thing `OSDController` gains: deterministic
/// teardown. Each window is built on demand and released in `windowWillClose`,
/// which takes its SwiftUI hierarchy with it — including, on a display page,
/// the `AmbientBackdrop` that would otherwise keep drifting behind a window
/// nobody can see.
@MainActor
final class WindowCoordinator: NSObject {
  private let model: AppModel

  private var settingsWindow: NSWindow?
  private var onboardingWindow: NSWindow?

  /// Outside the window on purpose — see `SettingsRouter`. The window's view
  /// tree is thrown away when it closes, so anything held in it would forget
  /// where it was, and a caller could not aim an already-open window at a page.
  private let settingsRouter = SettingsRouter()

  init(model: AppModel) {
    self.model = model
  }

  // MARK: - Settings

  /// Opens the settings window, optionally on a particular page.
  ///
  /// With no route it reopens where it was left, which is the right answer for
  /// the menu bar's gear: somebody who was in the middle of something and
  /// closed the window is going back to it. A route is for the callers that
  /// know better than the window does — dropping an application on the icon is
  /// about per-app rules, and landing on General would be a page of colour
  /// swatches in answer to a question about that app.
  func showSettings(route: SettingsRoute? = nil) {
    if let route { settingsRouter.route = route }

    if let settingsWindow {
      present(settingsWindow)
      return
    }

    // Resizable, and roomier than either of the two windows this replaces: a
    // sidebar and a column of cards need the width, and the DDC log inside the
    // diagnostics fold needs somewhere to go when it is opened.
    let window = makeWindow(
      title: "Pixel Pilot Settings",
      autosaveName: "settings",
      minSize: CGSize(width: 700, height: 520),
      defaultSize: CGSize(width: 820, height: 600),
      content: SettingsWindow(model: model, router: settingsRouter)
    )
    settingsWindow = window
    present(window)
  }

  // MARK: - Onboarding

  /// Shows the introduction if it has never been dismissed.
  ///
  /// Called once at launch. A fresh install would otherwise present a menu bar
  /// icon, two ungranted permissions and a keyboard key that quietly does
  /// nothing, with no explanation of any of it.
  func showOnboardingIfNeeded() {
    guard !Preferences.shared.global.hasCompletedOnboarding else { return }
    showOnboarding()
  }

  func showOnboarding() {
    if let onboardingWindow {
      present(onboardingWindow)
      return
    }

    let window = makeWindow(
      title: "Welcome to Pixel Pilot",
      autosaveName: "onboarding",
      minSize: CGSize(width: 560, height: 460),
      defaultSize: CGSize(width: 560, height: 460),
      isResizable: false,
      content: OnboardingFlow(model: model) { [weak self] in
        // On dismissal, whether finished or skipped. Showing it again to
        // someone who chose to skip it is worse than never having shown it.
        Preferences.shared.updateGlobal { $0.hasCompletedOnboarding = true }
        self?.onboardingWindow?.close()
      }
    )
    onboardingWindow = window
    present(window)
  }

  // MARK: - Building

  private func makeWindow(
    title: String,
    autosaveName: String,
    minSize: CGSize,
    defaultSize: CGSize,
    isResizable: Bool = true,
    content: some View
  ) -> NSWindow {
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    if isResizable { style.insert(.resizable) }

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: defaultSize),
      styleMask: style,
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.contentMinSize = minSize
    window.delegate = self
    window.identifier = NSUserInterfaceItemIdentifier(autosaveName)

    // The one place the environment is set up for a window's contents, so a
    // new window cannot be added without it — the failure mode `Layout`'s
    // documentation warns about, arranged out of existence. `withAppTheme()`
    // also paints the window's field and hands AppKit the matching appearance,
    // so a window added later is themed by being a window.
    window.contentView = NSHostingView(
      rootView: AnyView(
        content
          .withMotionTokens()
          .withAppTheme()
          .environment(\.surfaceDepth, .onOpaque)
      )
    )

    // After `contentView`, so the saved frame wins over the content's size
    // rather than the other way round.
    window.setFrameAutosaveName(autosaveName)
    if window.frame.size.width < minSize.width {
      window.setContentSize(defaultSize)
      window.center()
    }
    return window
  }

  private func present(_ window: NSWindow) {
    // `LSUIElement` apps are not active by default, and a window ordered front
    // without activating would come up behind whatever the user is in.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}

extension WindowCoordinator: NSWindowDelegate {
  /// Drops the window and its SwiftUI hierarchy rather than hiding them.
  ///
  /// Same argument as `OSDController.teardown()`: a window kept alive holds a
  /// backing store, a compositing layer and a live view tree for the rest of
  /// the session. On a display's page it also holds the `AmbientBackdrop`,
  /// which is a running animation — it had been parked via
  /// `controlActiveState`, which stops the drift but not the hierarchy. This
  /// stops both.
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    window.contentView = nil
    if window === settingsWindow { settingsWindow = nil }
    if window === onboardingWindow {
      // Closed by the window's own button rather than by finishing the flow.
      // Either way it has been dismissed, and that is the thing recorded.
      Preferences.shared.updateGlobal { $0.hasCompletedOnboarding = true }
      onboardingWindow = nil
    }
  }
}
