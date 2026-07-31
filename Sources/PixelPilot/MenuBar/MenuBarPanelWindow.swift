import AppKit
import SwiftUI

/// The popover under the status item.
///
/// **The invariant this type exists to keep.** `MenuBarPanel` documents that
/// SwiftUI only builds it while it is open, and that this is what pays for the
/// staggered entrance: the hierarchy is built fresh on every open, so the
/// arrival plays every single time and costs nothing at all in between. It is
/// also what stops the ambient wash — the one animation in this app that runs
/// on its own — the moment the panel is dismissed.
///
/// `MenuBarExtra` gave that for free. Doing it by hand means `close()` has to
/// destroy the hosting view rather than order the window out and leave it
/// standing, which is what almost every hand-rolled popover does. The test is
/// not subtle: with the panel closed the process must sit at 0.0 % CPU, and if
/// the hierarchy survived, the ambient drift keeps running and it will not.
///
/// `OSDController.teardown()` already makes the same move for the same reason.
@MainActor
final class MenuBarPanelWindow: NSObject {
  private var panel: NSPanel?
  private var hostingView: NSHostingView<AnyView>?
  private let onClose: () -> Void

  /// Live only while the panel is on screen.
  var isOpen: Bool { panel != nil }

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  /// Builds and shows a panel, anchored under `anchor`.
  func show(anchoredTo anchor: NSStatusBarButton, content: some View) {
    // The panel's counterpart to `WindowCoordinator.makeWindow`: the one place
    // the environment is set up, so the view inside can read every value rather
    // than installing them over itself and seeing the defaults.
    let hosting = NSHostingView(rootView: AnyView(
      content
        .withMotionTokens()
        // The field is painted below, over a vibrancy view — so the theme
        // supplies the colours and the ink but must not lay a second backdrop
        // inside the rounded corners.
        .withAppTheme(paintsWindow: false)
        // The panel's own material comes from the window it lives in, so its
        // cards must not lay a second sheet of glass over the first — that
        // reads as a flat wash with none of the depth either layer was drawing
        // for.
        .environment(\.surfaceDepth, .onGlass)
    ))
    hosting.sizingOptions = [.intrinsicContentSize]

    let panel = KeyablePanel(
      contentRect: .zero,
      // .nonactivatingPanel so opening the panel does not pull focus out of
      // whatever the user is working in — the same reasoning as the HUD, and
      // the reason `canBecomeKey` has to be overridden below: the panel still
      // needs key status to know when to dismiss itself.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    let theme = ThemeStore.shared.theme

    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    // Without this the material resolves against the system's light/dark
    // setting while everything drawn on top of it follows the theme — which
    // shows up as a pale popover under dark cards, or the reverse.
    background.appearance = theme.appearance
    background.wantsLayer = true
    background.layer?.cornerRadius = Layout.radiusPanel
    background.layer?.cornerCurve = .continuous
    background.layer?.masksToBounds = true

    // The material stays — the desktop blurring through it is real depth, and
    // this is the one surface in the app that has something behind it worth
    // sampling. What it does not have is a colour, so the theme's field goes
    // over it at most of the way to opaque: enough to read as the app's own
    // colour rather than as a grey system popover, and not so much that the
    // blur underneath stops showing through at the edges.
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = NSColor(theme.backdropTop)
      .withAlphaComponent(0.82).cgColor

    for subview in [tint, hosting] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(subview)
      NSLayoutConstraint.activate([
        subview.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        subview.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        subview.topAnchor.constraint(equalTo: background.topAnchor),
        subview.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      ])
    }

    panel.contentView = background
    panel.appearance = theme.appearance
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.delegate = self

    self.panel = panel
    self.hostingView = hosting

    position(panel, under: anchor)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Destroys the panel. Not `orderOut` — see the type documentation.
  func close() {
    guard let panel else { return }
    panel.delegate = nil
    panel.orderOut(nil)
    // This line is the whole point: dropping the content view drops the
    // `NSHostingView`, and with it the SwiftUI hierarchy, its observation and
    // its animations.
    panel.contentView = nil
    self.panel = nil
    hostingView = nil
  }

  private func position(_ panel: NSPanel, under anchor: NSStatusBarButton) {
    panel.layoutIfNeeded()
    let size = panel.contentView?.fittingSize ?? CGSize(width: 320, height: 200)
    panel.setContentSize(size)

    guard let anchorWindow = anchor.window else { return }
    let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = anchorWindow.screen ?? NSScreen.main

    var x = anchorFrame.midX - size.width / 2
    if let visible = screen?.visibleFrame {
      // Keep it on screen when the status item is near a corner, which is where
      // it usually is once a few other menu bar apps are installed.
      x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
    }
    panel.setFrameOrigin(CGPoint(x: x, y: anchorFrame.minY - size.height - 6))
  }
}

extension MenuBarPanelWindow: NSWindowDelegate {
  /// Borderless panels do not become key by default, and without key status
  /// there is no `resignKey` to dismiss on — which would mean a global event
  /// monitor, and a permission, for something the window server already knows.
  func windowDidResignKey(_ notification: Notification) {
    close()
    onClose()
  }
}

/// `NSPanel` refuses key status while borderless unless asked.
final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
