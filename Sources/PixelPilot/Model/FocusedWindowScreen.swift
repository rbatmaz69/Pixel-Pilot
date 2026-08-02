import AppKit
import ApplicationServices
import CoreGraphics

/// Where the person is actually working: the screen holding the frontmost
/// application's focused window.
///
/// Accessibility is the only way to ask. That sounds like a cost and is not one
/// here — the app already requires and holds that permission, because without it
/// the media keys cannot be intercepted at all. Nothing new is asked of anyone.
///
/// **This is called from inside a `CGEventTap` callback**, which is the fact
/// that shapes everything below. A tap that takes too long to answer is
/// disabled by macOS outright, and an Accessibility read is inter-process: it
/// answers in about a millisecond against a healthy application and in whatever
/// the timeout allows against a wedged one. So the timeout is set explicitly and
/// short, and the caller caches — see `AppModel.focusedDisplay`, where a burst
/// of key repeats is answered from memory rather than from six round trips a
/// second.
enum FocusedWindowScreen {
  /// Long enough for any application that is going to answer, short enough that
  /// one that is not cannot cost the event tap its life. The system default is
  /// six seconds, which in this position would be a hang.
  private static let messagingTimeout: Float = 0.05

  /// The display holding the frontmost application's focused window, or nil if
  /// that cannot be established.
  ///
  /// Nil is a normal answer rather than a failure: the Finder with no window
  /// open, an application that does not expose one, a permission not yet
  /// granted. The caller has a fallback for exactly that reason.
  static func current() -> CGDirectDisplayID? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
    return displayID(forProcessIdentifier: frontmost.processIdentifier)
  }

  static func displayID(forProcessIdentifier pid: pid_t) -> CGDirectDisplayID? {
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, messagingTimeout)

    guard let window = copy(AXUIElement.self, from: application, attribute: kAXFocusedWindowAttribute)
      // A focused window is the precise answer; the main one is the reasonable
      // stand-in for an application whose focus is on something that is not a
      // window — a menu, a panel, a sheet the app does not report.
      ?? copy(AXUIElement.self, from: application, attribute: kAXMainWindowAttribute)
    else { return nil }

    guard let origin = point(from: window, attribute: kAXPositionAttribute),
          let size = size(from: window, attribute: kAXSizeAttribute)
    else { return nil }

    return screen(containing: origin, size: size)?.displayID
  }

  // MARK: - Reading

  private static func copy<T>(
    _ type: T.Type, from element: AXUIElement, attribute: String
  ) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? T
  }

  private static func point(from element: AXUIElement, attribute: String) -> CGPoint? {
    guard let value = copy(AXValue.self, from: element, attribute: attribute) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return point
  }

  private static func size(from element: AXUIElement, attribute: String) -> CGSize? {
    guard let value = copy(AXValue.self, from: element, attribute: attribute) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return size
  }

  // MARK: - Geometry

  /// Which screen a window sits on, given its frame in Accessibility's
  /// coordinates.
  ///
  /// The two coordinate systems disagree about which way is up. Accessibility
  /// puts the origin at the **top** left of the primary display with y growing
  /// downward; Cocoa puts it at the bottom left with y growing upward. Compared
  /// without converting, a window on a screen above the primary one lands below
  /// it, which is the sort of mistake that looks like it works until somebody
  /// stacks their monitors vertically.
  ///
  /// The window's centre is what gets tested rather than its origin. A window
  /// straddling two screens belongs to the one it is mostly on, and a title bar
  /// dragged a few points onto a neighbour is not a move.
  private static func screen(containing origin: CGPoint, size: CGSize) -> NSScreen? {
    // `screens[0]` is the display whose origin is (0, 0) — the one both
    // coordinate systems are measured from.
    guard let primary = NSScreen.screens.first else { return nil }

    let centre = CGPoint(
      x: origin.x + size.width / 2,
      y: primary.frame.maxY - (origin.y + size.height / 2)
    )
    return NSScreen.screens.first { $0.frame.contains(centre) }
  }
}
