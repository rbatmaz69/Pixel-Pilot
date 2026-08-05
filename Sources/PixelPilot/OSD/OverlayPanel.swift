import AppKit
import SwiftUI

/// The borderless panel both on-screen overlays are built from.
///
/// Extracted when a second one appeared. The configuration is not obvious and
/// two copies of it would drift: `.nonactivatingPanel` so showing something
/// never steals focus from what the user is working in, no window shadow
/// because the glass material draws its own and two of them make a visible
/// double edge, and `.screenSaver` level so it clears full-screen apps.
@MainActor
enum OverlayPanel {
  /// AppKit's side of the reduce-motion setting.
  ///
  /// These controllers live outside the SwiftUI environment, so `MotionTokens`
  /// cannot reach them. Without this the window would keep fading and springing
  /// in while everything drawn inside it had been flattened — half-honoured is
  /// worse than not honoured, because it looks like the setting is broken.
  static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// - Parameter acceptsMouse: Whether the panel takes mouse events at all.
  ///
  ///   Off for the identify overlay, and that is not a preference: it covers a
  ///   whole screen, so accepting events would make identifying the displays
  ///   mean not being able to click on any of them.
  ///
  ///   On for the HUD, which is the size of its own plate. The cost is stated
  ///   plainly because it is real: for the second or so the HUD is up, a click
  ///   on those 210 points goes to it rather than through it. That is the price
  ///   of being able to grab the thing you are already looking at, and it is
  ///   bounded by the panel being small, short-lived and always in the same
  ///   place.
  /// - Parameter canBecomeKey: Whether the panel takes the keyboard.
  ///
  ///   False everywhere except the test patterns, and the exception is worth
  ///   stating because it contradicts the rule the rest of this file is built
  ///   on. This app is never the active one, deliberately: showing a HUD or
  ///   identifying the displays must not take focus from whatever is being
  ///   worked in, because nobody asked for either of those at that moment.
  ///
  ///   A test pattern is the opposite situation. It was opened on purpose, it
  ///   covers the whole screen, and the only real failure mode is not being
  ///   able to get out of it. Escape is the obvious way out and Escape needs
  ///   the keyboard, so this one panel takes it.
  static func make(
    content: AnyView, acceptsMouse: Bool = false, canBecomeKey: Bool = false
  ) -> (panel: NSPanel, hosting: NSHostingView<AnyView>) {
    let hosting: NSHostingView<AnyView> = acceptsMouse
      ? InteractiveHostingView(rootView: content)
      : NSHostingView(rootView: content)
    hosting.sizingOptions = [.intrinsicContentSize]

    let panel: NSPanel = canBecomeKey
      ? KeyablePanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      : NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
    panel.contentView = hosting
    // Both overlays are glass over whatever is on screen, and glass resolves
    // against an appearance. Left to the system's it would be light while the
    // theme is deep, which is exactly the combination that turns a HUD into a
    // white slab.
    panel.appearance = ThemeStore.shared.theme.appearance
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovable = false
    panel.ignoresMouseEvents = !acceptsMouse
    // Tracking areas below are what report the pointer, but a panel that never
    // asked for moved events is a panel AppKit has no reason to follow the
    // pointer over.
    panel.acceptsMouseMovedEvents = acceptsMouse
    panel.hidesOnDeactivate = false
    panel.level = .screenSaver
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .stationary,
    ]
    panel.alphaValue = 0
    return (panel, hosting)
  }

  /// Sizes the panel to its content and puts it where `place` says, given the
  /// screen frame and the resulting size.
  static func position(
    _ panel: NSPanel, on screen: NSScreen, place: (CGRect, CGSize) -> CGPoint
  ) {
    panel.layoutIfNeeded()
    let size = panel.contentView?.fittingSize ?? CGSize(width: 200, height: 150)
    panel.setContentSize(size)
    panel.setFrameOrigin(place(screen.frame, size))
  }

  /// A panel that will accept the keyboard.
  ///
  /// `NSPanel` refuses by default when it is borderless — there is no title bar,
  /// so AppKit assumes there is nothing to type into. Overriding is the only
  /// way, and `canBecomeMain` stays false: this needs key events, not to be the
  /// application's main window.
  final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  /// A hosting view that can be pointed at and clicked by a background app.
  ///
  /// Two AppKit facts, both of which come from the same root: this app is never
  /// the active one. It has no Dock icon, and both overlays are
  /// `.nonactivatingPanel` precisely so that showing something never takes
  /// focus from what is being worked in.
  ///
  /// **Hover.** A tracking area is live only while its application is active
  /// unless it asks for `.activeAlways`, and SwiftUI's `.onHover` does not ask.
  /// So the hover it reports is a hover that never happens here. The option has
  /// no SwiftUI spelling, which is why this is a subclass rather than a
  /// modifier.
  ///
  /// **The first click.** A click into a window of an inactive app is normally
  /// spent activating it. This panel activates nothing, so that click would
  /// vanish into a change of state that does not exist, and the handle would
  /// only move on the second attempt.
  ///
  /// It is the content view itself rather than an overlay on top of it, and
  /// that is the fix for the first attempt at this: a subview added at build
  /// time has a zero frame, the panel is not sized until later, and a tracking
  /// area over nothing tracks nothing.
  final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?

    /// Tags the one tracking area that belongs to this class.
    ///
    /// `NSHostingView` puts up its own for SwiftUI's sake, and they may well be
    /// owned by this same object. Removing them by owner would take SwiftUI's
    /// with them, and answering their crossings would report the pointer
    /// entering the HUD every time it passed over a button inside it.
    static var hoverTag: String { "dev.rb.pixelpilot.hover" }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas where isOurs(area) {
        removeTrackingArea(area)
      }
      addTrackingArea(NSTrackingArea(
        // Ignored, because `.inVisibleRect` keeps the area on the view's own
        // extent as it changes. That is the fix for the first attempt at this,
        // where a fixed rect was measured before the panel had a size.
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self,
        userInfo: ["tag": Self.hoverTag]
      ))
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      guard event.trackingArea.map(isOurs) == true else { return }
      onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      guard event.trackingArea.map(isOurs) == true else { return }
      onHoverChanged?(false)
    }

    private func isOurs(_ area: NSTrackingArea) -> Bool {
      area.userInfo?["tag"] as? String == Self.hoverTag
    }
  }

  static func fadeIn(_ panel: NSPanel, duration: TimeInterval) {
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      panel.animator().alphaValue = 1
    }
  }
}
