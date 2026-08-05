import AppKit
import PixelPilotCore
import SwiftUI

/// Shows test patterns on one display, until dismissed.
///
/// Built from the same `OverlayPanel` as the HUD and the identify overlay, and
/// structured like `IdentifyController` — but with three deliberate differences
/// from it, each of which is a rule that file states being broken on purpose:
///
/// **It stays.** No dismiss task. Looking for a dead pixel takes as long as it
/// takes.
///
/// **It takes the keyboard and the mouse.** `OverlayPanel` argues against a
/// full-screen panel accepting events, correctly, for an overlay nobody asked
/// for. This one was opened deliberately and the only real failure is being
/// unable to leave, so Escape has to arrive somewhere.
///
/// **It takes the app's own tables off the display.** A banding test seen
/// through a lifted tone curve is a statement about the tone curve. `suspend`
/// rather than `clear` because the warmth and finish have to come back
/// afterwards, and only the dimmer still knows what they were.
@MainActor
final class TestPatternController {
  private var panel: NSPanel?
  private var displayID: CGDirectDisplayID?
  private var escapeMonitor: Any?

  private(set) var pattern: TestPattern = .white

  private let gamma: GammaDimmer

  init(gamma: GammaDimmer = .shared) {
    self.gamma = gamma
  }

  var isShowing: Bool { panel != nil }

  func show(on displayID: CGDirectDisplayID, named name: String) {
    hide()

    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }

    self.displayID = displayID
    pattern = .white
    gamma.suspend(displayID)

    let made = OverlayPanel.make(
      content: AnyView(EmptyView()), acceptsMouse: true, canBecomeKey: true
    )
    made.panel.setFrame(screen.frame, display: false)
    panel = made.panel
    render(name: name, into: made.hosting)

    made.panel.alphaValue = 1
    made.panel.makeKeyAndOrderFront(nil)
    // A background app's window does not come forward on its own. This is the
    // one place the app activates, and it is what makes Escape reach us.
    NSApp.activate(ignoringOtherApps: true)

    // Escape as well as the panel's own key handling: a SwiftUI `onKeyPress`
    // inside a borderless panel is at the mercy of what has first responder,
    // and the way out of a full-screen overlay is the one thing that cannot be
    // allowed to depend on that.
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isShowing else { return event }
      switch event.keyCode {
      case 53: hide(); return nil            // esc
      case 123: step(-1, name: name); return nil  // left
      case 124, 49: step(1, name: name); return nil // right, space
      default: return event
      }
    }
  }

  func hide() {
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
    }
    escapeMonitor = nil

    // Before the panel goes, so the display is never briefly showing the
    // desktop with our tables still off it.
    if let displayID {
      gamma.resume(displayID)
    }
    displayID = nil

    panel?.orderOut(nil)
    // Same reason as everywhere else in this app: dropping the content view
    // drops the SwiftUI hierarchy rather than leaving it standing.
    panel?.contentView = nil
    panel = nil
  }

  private func step(_ delta: Int, name: String) {
    let all = TestPattern.allCases
    guard let current = all.firstIndex(of: pattern) else { return }
    let next = (current + delta + all.count) % all.count
    pattern = all[next]
    if let hosting = panel?.contentView as? NSHostingView<AnyView> {
      render(name: name, into: hosting)
    }
  }

  private func render(name: String, into hosting: NSHostingView<AnyView>) {
    let all = TestPattern.allCases
    hosting.rootView = AnyView(
      TestPatternView(
        pattern: pattern,
        displayName: name,
        index: all.firstIndex(of: pattern) ?? 0,
        total: all.count,
        onNext: { [weak self] in self?.step(1, name: name) },
        onPrevious: { [weak self] in self?.step(-1, name: name) },
        onClose: { [weak self] in self?.hide() }
      )
      // No theme and no motion tokens, unlike every other overlay. A test
      // pattern tinted by the app's accent colour would be testing the app.
      .withMotionTokens()
    )
  }

  isolated deinit {
    hide()
  }
}
