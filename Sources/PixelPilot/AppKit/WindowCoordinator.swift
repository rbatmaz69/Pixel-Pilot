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

  /// Set by the app delegate on the way out, so a window closing because the
  /// app is quitting can be told apart from a window somebody closed.
  var isQuitting = false

  /// Outside the window on purpose — see `SettingsRouter`. The window's view
  /// tree is thrown away when it closes, so anything held in it would forget
  /// where it was, and a caller could not aim an already-open window at a page.
  private let settingsRouter = SettingsRouter()

  init(model: AppModel) {
    self.model = model
    super.init()
    // Weakly, so the model's hook cannot keep this alive. The coordinator owns
    // the model, not the other way round.
    model.onShowWelcome = { [weak self] in self?.showOnboarding() }
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
    let hadSavedFrame = Self.hasSavedFrame(autosaveName)
    window.setFrameAutosaveName(autosaveName)
    if window.frame.size.width < minSize.width {
      window.setContentSize(defaultSize)
      window.center()
    }

    // **Position is checked separately from size, and that separation is the
    // whole point.** The size check above cannot catch a window that is exactly
    // the right size and in the wrong place, and on a fresh install that is
    // every window: `NSWindow(contentRect:)` is given an origin of `.zero`,
    // which in AppKit's coordinates is the *bottom left* of the screen, behind
    // the Dock. With no saved frame to restore and a size that passes, nothing
    // ever moved it.
    //
    // Onboarding is where that actually hurt. It opened on every launch, at the
    // bottom corner behind the Dock, was never noticed and so never dismissed —
    // and since the flag is only written when it is dismissed, it opened there
    // again the next time, and the next. Reinstalling could not help: the
    // window was never the thing that was broken.
    if !hadSavedFrame {
      window.center()
    } else if let corrected = Self.broughtOnScreen(window.frame) {
      window.setFrame(corrected, display: false)
    }
    return window
  }

  /// Whether AppKit has a remembered position for this window.
  ///
  /// Read before `setFrameAutosaveName`, because that call is what creates the
  /// entry. The key is AppKit's own and is stable.
  private static func hasSavedFrame(_ autosaveName: String) -> Bool {
    UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
  }

  /// The same frame, moved the least it can be to sit inside the usable area —
  /// or `nil` when it is already there and should be left alone.
  ///
  /// Nudged rather than re-centred, because where a window is put is the user's
  /// business: a window they dragged half off the edge should come back to the
  /// edge, not jump to the middle of the screen. This also covers the frame
  /// saved on a monitor that is no longer plugged in, which is the same failure
  /// arriving by a different route.
  ///
  /// `visibleFrame` rather than `frame`, so "usable" means what it says: not
  /// under the menu bar and not behind the Dock.
  private static func broughtOnScreen(_ frame: CGRect) -> CGRect? {
    let screen = NSScreen.screens.max {
      $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
    }
    guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
    guard !visible.contains(frame) else { return nil }

    // Too big to fit anywhere is not a placement problem, and shoving it into a
    // corner would not help. `center` at least puts the middle of it where
    // somebody is looking.
    guard frame.width <= visible.width, frame.height <= visible.height else {
      return CGRect(
        x: visible.midX - frame.width / 2,
        y: visible.midY - frame.height / 2,
        width: frame.width,
        height: frame.height
      )
    }

    return CGRect(
      x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
      y: min(max(frame.minY, visible.minY), visible.maxY - frame.height),
      width: frame.width,
      height: frame.height
    )
  }

  // Both rules are worth testing and neither needs a `WindowCoordinator`, which
  // cannot be built without an `AppModel` and every display on the machine.
  static func broughtOnScreenForTesting(_ frame: CGRect) -> CGRect? { broughtOnScreen(frame) }
  static func hasSavedFrameForTesting(_ name: String) -> Bool { hasSavedFrame(name) }

  private func present(_ window: NSWindow) {
    // `LSUIElement` apps are not active by default, and a window ordered front
    // without activating would come up behind whatever the user is in.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // And again regardless, because activation is a request rather than an
    // instruction — the system can decline it for an accessory app, and then
    // `makeKeyAndOrderFront` alone leaves the window sitting behind whatever is
    // in front. This orders it above other applications' windows either way.
    window.orderFrontRegardless()
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
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
      // Either way it has been dismissed, and that is the thing recorded — but
      // only when a person did it. Quitting closes every window too, and
      // treating that as "read it" is how somebody who never saw the window
      // ends up permanently unable to: it opened somewhere they did not notice,
      // they quit or reinstalled, and it recorded itself as seen on the way
      // out. `Scripts/install.sh` quits the running copy, so every reinstall
      // burned the one chance to show it.
      if !isQuitting {
        Preferences.shared.updateGlobal { $0.hasCompletedOnboarding = true }
      }
      onboardingWindow = nil
    }
  }
}
