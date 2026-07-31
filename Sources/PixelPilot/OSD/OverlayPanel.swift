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

  static func make(content: AnyView) -> (panel: NSPanel, hosting: NSHostingView<AnyView>) {
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = [.intrinsicContentSize]

    let panel = NSPanel(
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
    panel.ignoresMouseEvents = true
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

  static func fadeIn(_ panel: NSPanel, duration: TimeInterval) {
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      panel.animator().alphaValue = 1
    }
  }
}
