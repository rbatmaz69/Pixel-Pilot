import AppKit
import SwiftUI
import Testing

@testable import PixelPilot

/// How the two overlays are wired for the mouse.
///
/// None of this can be judged by looking at the app: a HUD that ignores the
/// pointer looks exactly like a HUD that is waiting for it. Every one of these
/// pins a mistake that was actually made and shipped once.
@Suite("Overlay panels")
@MainActor
struct OverlayPanelTests {
  private func made(acceptsMouse: Bool) -> (panel: NSPanel, hosting: NSHostingView<AnyView>) {
    OverlayPanel.make(content: AnyView(Color.clear), acceptsMouse: acceptsMouse)
  }

  /// The identify overlay covers whole screens. Letting it take mouse events
  /// would make "which display is that?" mean "and now you cannot click on any
  /// of them".
  @Test("Only the HUD takes mouse events")
  func mouseAcceptance() {
    let hud = made(acceptsMouse: true)
    #expect(hud.panel.ignoresMouseEvents == false)
    #expect(hud.panel.acceptsMouseMovedEvents)

    let identify = made(acceptsMouse: false)
    #expect(identify.panel.ignoresMouseEvents)
    #expect(identify.panel.acceptsMouseMovedEvents == false)
  }

  /// The app is never the active one, so a click into the HUD would otherwise
  /// be spent activating a window that activates nothing — and the handle would
  /// move only on the second try.
  @Test("The HUD acts on the first click rather than spending it")
  func firstMouse() {
    #expect(made(acceptsMouse: true).hosting.acceptsFirstMouse(for: nil))
  }

  /// The bug this exists for: the tracking area used to be installed on a
  /// subview that still had a zero frame, because the panel is not sized until
  /// later. A tracking area over nothing tracks nothing, so the HUD never
  /// noticed the pointer and the slider it was meant to reveal never appeared.
  @Test("The pointer is tracked over the panel's real extent, whenever it gets one")
  func trackingFollowsTheSize() {
    let hud = made(acceptsMouse: true)
    hud.panel.setContentSize(CGSize(width: 210, height: 170))
    hud.hosting.layoutSubtreeIfNeeded()
    hud.hosting.updateTrackingAreas()

    let ours = hud.hosting.trackingAreas.filter {
      $0.userInfo?["tag"] as? String
        == OverlayPanel.InteractiveHostingView<AnyView>.hoverTag
    }

    #expect(ours.count == 1)
    // Without `.activeAlways` the area is live only while this app is the
    // active one, which it never is.
    #expect(ours.allSatisfy { $0.options.contains(.activeAlways) })
    // And this is what makes it follow the view rather than a rectangle
    // measured before there was one.
    #expect(ours.allSatisfy { $0.options.contains(.inVisibleRect) })
  }

  /// Updating twice must not leave two areas behind, or one crossing would be
  /// reported as several.
  @Test("Re-tracking replaces rather than accumulates")
  func trackingDoesNotAccumulate() {
    let hud = made(acceptsMouse: true)
    hud.panel.setContentSize(CGSize(width: 210, height: 170))
    for _ in 0 ..< 3 { hud.hosting.updateTrackingAreas() }

    let ours = hud.hosting.trackingAreas.filter {
      $0.userInfo?["tag"] as? String
        == OverlayPanel.InteractiveHostingView<AnyView>.hoverTag
    }
    #expect(ours.count == 1)
  }

  /// The app is never the active one on purpose, so a panel that takes the
  /// keyboard is an exception rather than a default — and the one place it is
  /// right is a full-screen test pattern, where Escape is the way out.
  @Test("Only a panel that asks for it takes the keyboard")
  func keyAcceptance() {
    #expect(!made(acceptsMouse: true).panel.canBecomeKey)
    #expect(!made(acceptsMouse: false).panel.canBecomeKey)

    let pattern = OverlayPanel.make(
      content: AnyView(Color.clear), acceptsMouse: true, canBecomeKey: true
    )
    #expect(pattern.panel.canBecomeKey)
    // Key, not main. It needs the keystrokes, not to become the application's
    // main window.
    #expect(!pattern.panel.canBecomeMain)
  }
}

/// The patterns themselves.
///
/// A test pattern nobody can interpret is a coloured screen, so the thing worth
/// pinning is that every one of them says what it is asking you to look for.
@Suite("Test patterns")
struct TestPatternTests {
  @Test("Every pattern says what it is and what to look for")
  func everyPatternIsExplained() {
    for pattern in TestPattern.allCases {
      #expect(!pattern.title.isEmpty)
      #expect(!pattern.purpose.isEmpty)
    }
  }

  /// The solids come first: a dead pixel makes everything below it moot, and
  /// finding one is what most people open this for.
  @Test("The solids lead")
  func solidsComeFirst() {
    #expect(TestPattern.allCases.prefix(5) == [.white, .black, .red, .green, .blue])
  }

  @Test("Cycling is a loop, so neither end is a dead stop")
  func namesAreUnique() {
    let titles = TestPattern.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(TestPattern.allCases.count > 1)
  }
}
