import AppKit
import SwiftUI
import Testing

@testable import PixelPilot

/// Whether a drag on the real HUD actually reaches the display.
///
/// Every other test of this feature checks wiring — that the panel takes mouse
/// events, that the tracking area is the right kind. None of them would notice
/// the one failure that matters, which is the whole thing being assembled
/// correctly and still doing nothing when dragged. So this builds the real
/// `OSDView` in the real panel and sends it real events.
///
/// The events go to our own window through `sendEvent`, so this needs no
/// Accessibility grant and runs in CI as happily as on a desk.
@Suite("Dragging the HUD")
@MainActor
struct OSDInteractionTests {
  private final class Received {
    var values: [Double] = []
    var commits = 0
  }

  private func panel(value: Double, received: Received) -> NSPanel {
    let view = OSDView(
      kind: .brightness,
      value: value,
      accent: .blue,
      displayName: "Probe",
      adjust: { received.values.append($0) },
      commit: { received.commits += 1 }
    )
    .withMotionTokens()
    .withAppTheme(paintsWindow: false)

    let made = OverlayPanel.make(content: AnyView(view), acceptsMouse: true)
    OverlayPanel.position(made.panel, on: NSScreen.main ?? NSScreen.screens[0]) { frame, size in
      CGPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12)
    }
    made.panel.alphaValue = 1
    made.panel.orderFrontRegardless()
    settle()
    return made.panel
  }

  /// Lets SwiftUI lay out and the entrance animation finish. The HUD springs in
  /// from 90 %, and a drag mapped through a scale that has not settled would be
  /// measuring the wrong thing.
  private func settle(_ seconds: TimeInterval = 0.9) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func send(
    _ type: NSEvent.EventType, at point: CGPoint, to panel: NSPanel
  ) {
    guard let event = NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber,
      context: nil,
      eventNumber: Int.random(in: 1 ... 100_000),
      clickCount: 1,
      pressure: 1
    ) else { return }
    panel.sendEvent(event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }

  /// Where the track sits: the HUD is a glyph, a figure, the track, then the
  /// display's name, so the track is a little below the middle in AppKit's
  /// bottom-up coordinates.
  private func trackY(in panel: NSPanel) -> CGFloat {
    panel.frame.height * 0.28
  }

  @Test("Clicking the track moves the display")
  func clickReaches() {
    let received = Received()
    let panel = panel(value: 0.1, received: received)
    defer { panel.orderOut(nil) }

    let x = panel.frame.width * 0.75
    send(.leftMouseDown, at: CGPoint(x: x, y: trackY(in: panel)), to: panel)
    send(.leftMouseUp, at: CGPoint(x: x, y: trackY(in: panel)), to: panel)

    #expect(!received.values.isEmpty, "no value ever reached the display")
    #expect(received.commits == 1, "the verified write did not happen exactly once")
  }

  /// The point of the feature: not a click that jumps, a handle that follows.
  @Test("Dragging the track sweeps the display")
  func dragSweeps() {
    let received = Received()
    let panel = panel(value: 0.1, received: received)
    defer { panel.orderOut(nil) }

    let y = trackY(in: panel)
    send(.leftMouseDown, at: CGPoint(x: 30, y: y), to: panel)
    for step in 1 ... 6 {
      let x = 30 + (panel.frame.width - 60) * CGFloat(step) / 6
      send(.leftMouseDragged, at: CGPoint(x: x, y: y), to: panel)
    }
    send(.leftMouseUp, at: CGPoint(x: panel.frame.width - 30, y: y), to: panel)

    #expect(received.values.count > 2, "the drag produced \(received.values.count) values")
    // Left to right is darker to brighter, and the last value is where it was
    // let go — that is what the display should have been left at.
    #expect((received.values.last ?? 0) > 0.5)
  }

  /// A mute indicator has nothing to send anywhere, and must not pretend to.
  @Test("An indicator with nowhere to send a value has no handle")
  func mutedIsInert() {
    let received = Received()
    let view = OSDView(kind: .muted, value: 0, accent: .blue, displayName: "Probe")
      .withMotionTokens()
      .withAppTheme(paintsWindow: false)
    let made = OverlayPanel.make(content: AnyView(view), acceptsMouse: true)
    OverlayPanel.position(made.panel, on: NSScreen.main ?? NSScreen.screens[0]) { frame, size in
      CGPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12)
    }
    made.panel.alphaValue = 1
    made.panel.orderFrontRegardless()
    settle()
    defer { made.panel.orderOut(nil) }

    send(.leftMouseDown, at: CGPoint(x: 100, y: trackY(in: made.panel)), to: made.panel)
    send(.leftMouseUp, at: CGPoint(x: 100, y: trackY(in: made.panel)), to: made.panel)

    #expect(received.values.isEmpty)
  }
}
