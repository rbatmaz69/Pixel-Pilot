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

    // The visual effect view stays whatever the style is. It owns the corner
    // radius, the masking and the anchors for both subviews, so swapping it for
    // a plain view under a style with no material would mean re-plumbing all of
    // that to achieve something the tint below already does. Its material is
    // switched off instead — `.inactive` stops it sampling the desktop at all,
    // which is a pass saved on a window that opens on every click of the menu
    // bar icon.
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = theme.usesMaterial ? .active : .inactive
    // Without this the material resolves against the system's light/dark
    // setting while everything drawn on top of it follows the theme — which
    // shows up as a pale popover under dark cards, or the reverse.
    background.appearance = theme.appearance
    background.wantsLayer = true
    // Two roundings, because they cut two different things and neither one does
    // the other's job.
    //
    // `maskImage` is what shapes the **material**. A view blending behind the
    // window does not take its extent from its layer — the blur is done by the
    // window server against the region this mask describes, and with no mask
    // that region is the window's square bounds. On a dark desktop nobody sees
    // it. Over a white window it is a flat pale rectangle with hard edges
    // standing out past every corner, which is what this looked like.
    background.maskImage = Self.roundedMask(radius: Layout.radiusPanel)
    // And the layer radius is what clips the **subviews** — the tint and the
    // hosting view are ordinary children and the mask above does not touch
    // them. Dropping this would put square corners of solid colour back inside
    // a correctly rounded material.
    background.layer?.cornerRadius = Layout.radiusPanel
    background.layer?.cornerCurve = .continuous
    background.layer?.masksToBounds = true

    // Where the material survives, the desktop blurring through it is real
    // depth, and this is the one surface in the app that has something behind
    // it worth sampling. What it does not have is a colour, so the theme's
    // field goes over it at most of the way to opaque: enough to read as the
    // app's own colour rather than as a grey system popover, and not so much
    // that the blur underneath stops showing through at the edges.
    //
    // How much of "most of the way" is the style's to say, and at 1 the answer
    // is that nothing of the desktop survives — which is how a flat panel is
    // had without touching a line of the structure above.
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = NSColor(theme.backdropTop)
      .withAlphaComponent(theme.panelTintOpacity).cgColor

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
    // The panel is built at `.zero` and sized here, so the shape the shadow was
    // derived from is not the shape on screen. AppKit does not re-derive it on
    // its own, and the result is a shadow cast by the wrong rectangle — the
    // same class of fault as the square material above, and just as invisible
    // until there is something pale behind it.
    panel.invalidateShadow()
  }

  /// A rounded rectangle to shape the behind-window blur with.
  ///
  /// Stretchable rather than drawn at the panel's size: the cap insets pin the
  /// four corners and let the middle repeat, so one small image fits a panel of
  /// any height — and the height here changes with the number of displays.
  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.set()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
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
