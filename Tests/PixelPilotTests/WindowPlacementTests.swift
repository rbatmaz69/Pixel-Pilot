import AppKit
import PixelPilotCore
import SwiftUI
import Testing

@testable import PixelPilot

/// Where a window lands the first time it is ever opened, and what happens to a
/// remembered position that no longer works.
///
/// Written after the onboarding window turned out to be opening on *every*
/// launch and never being seen. Three things had to be true at once, and they
/// were:
///
/// - `NSWindow(contentRect:)` is given an origin of `.zero`, which in AppKit's
///   coordinates is the bottom-left corner of the screen rather than the
///   top-left. With no remembered position, nothing moved it from there.
/// - The one recovery check tested the window's *size*, which was right, so it
///   never fired.
/// - Being an accessory app's window, it sank behind whatever was in front.
///
/// So it opened in a corner, half under the Dock, behind the frontmost app.
/// Nobody saw it, so nobody dismissed it — and the "already seen this" flag is
/// only written on dismissal, so it opened there again on the next launch, and
/// the next. Reinstalling could not help, because the install was never the
/// thing that was wrong.
@Suite("Window placement")
@MainActor
struct WindowPlacementTests {
  private var visible: CGRect {
    (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
  }

  /// The exact shape of the bug. Nothing about the window's size is wrong,
  /// which is why a size check let it through.
  @Test("A window at the origin is off the usable area and is brought back")
  func originIsCorrected() throws {
    let atOrigin = CGRect(x: 0, y: 0, width: 560, height: 492)
    let corrected = try #require(
      WindowCoordinator.broughtOnScreenForTesting(atOrigin),
      "a window sitting under the Dock was left where it was"
    )

    #expect(visible.contains(corrected))
    #expect(corrected.size == atOrigin.size, "only the position should change")
    // Nudged, not re-centred: it came from the left edge and stays there.
    #expect(corrected.minX == visible.minX)
  }

  /// The real frame this was found with — saved as `86 0 560 492`, which put
  /// the bottom of the window below the bottom of the screen.
  @Test("The frame this was actually found with is corrected")
  func theRealFrame() throws {
    let stored = CGRect(x: 86, y: -30, width: 560, height: 492)
    let corrected = try #require(WindowCoordinator.broughtOnScreenForTesting(stored))

    #expect(visible.contains(corrected))
    // Moved up just enough, and not sideways at all — it was never wrong across.
    #expect(corrected.minX == 86)
    #expect(corrected.minY == visible.minY)
  }

  /// A frame saved on a monitor that has since been unplugged is the same
  /// failure by another route.
  @Test("A frame off every screen comes back")
  func offScreenComesBack() throws {
    for frame in [
      CGRect(x: 12_000, y: 9_000, width: 560, height: 492),
      CGRect(x: -4_000, y: 100, width: 560, height: 492),
    ] {
      let corrected = try #require(WindowCoordinator.broughtOnScreenForTesting(frame))
      #expect(visible.contains(corrected))
    }
  }

  /// The other half of the rule. Where a window is put is the user's business,
  /// so a window already inside the usable area is never moved — an app that
  /// re-centres a window every time it opens is an app fighting the person
  /// using it.
  @Test("A window that is already usable is left exactly alone")
  func usablePlacementIsKept() {
    let placed = CGRect(
      x: visible.minX + 120, y: visible.minY + 90, width: 560, height: 492
    )
    #expect(WindowCoordinator.broughtOnScreenForTesting(placed) == nil)

    // Flush into the corner of the usable area counts as inside it.
    let corner = CGRect(
      x: visible.minX, y: visible.minY, width: 560, height: 492
    )
    #expect(WindowCoordinator.broughtOnScreenForTesting(corner) == nil)
  }

  /// Too big to fit is not a placement problem, and shoving it into a corner
  /// would not help.
  @Test("A window larger than the screen is centred rather than jammed")
  func oversizedIsCentred() throws {
    let huge = CGRect(
      x: 0, y: 0, width: visible.width + 400, height: visible.height + 400
    )
    let corrected = try #require(WindowCoordinator.broughtOnScreenForTesting(huge))
    #expect(abs(corrected.midX - visible.midX) < 0.5)
    #expect(abs(corrected.midY - visible.midY) < 0.5)
  }

  /// The welcome guide is shown once and records that it has been, and that
  /// record lives with the user's settings rather than inside the app bundle —
  /// so deleting the app cannot bring it back, and reinstalling is the obvious
  /// thing to try and the one thing that cannot work. Until this, there was no
  /// way at all to see it a second time.
  ///
  /// The coordinator owns the model, so the way back is a closure the
  /// coordinator sets rather than a reference the model holds.
  @Test("The welcome guide can be asked for again")
  func welcomeCanBeReopened() {
    let model = AppModel(
      gamma: GammaDimmer(),
      preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )

    // Nothing wired yet: asking must be harmless rather than a crash.
    model.showWelcome()

    var asked = 0
    model.onShowWelcome = { asked += 1 }
    model.showWelcome()
    #expect(asked == 1)
  }

  /// And the half above cannot catch: that a real coordinator wires itself up.
  /// A hook nobody sets is a button that does nothing, which is the same
  /// outcome as not having added it.
  @Test("A coordinator wires the guide up, and asking opens a window")
  func coordinatorWiresTheGuide() throws {
    let model = AppModel(
      gamma: GammaDimmer(),
      preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
    let windows = WindowCoordinator(model: model)
    #expect(model.onShowWelcome != nil, "the button would do nothing")

    let before = NSApp.windows.count
    model.showWelcome()
    defer { NSApp.windows.forEach { if $0.title.isEmpty == false { $0.close() } } }

    #expect(NSApp.windows.count > before, "asking for the guide opened nothing")
    // Held so the coordinator is not torn down before the window it made.
    withExtendedLifetime(windows) {}
  }

  /// "Has this window ever been placed" has to be asked *before*
  /// `setFrameAutosaveName`, because that call is what creates the entry — ask
  /// afterwards and the answer is always yes, which is how a fresh window ends
  /// up treated as one somebody positioned.
  @Test("A window with no remembered position is recognised as new")
  func freshWindowHasNoSavedFrame() {
    let name = "test.\(UUID().uuidString)"
    #expect(!WindowCoordinator.hasSavedFrameForTesting(name))

    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 560, height: 492),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      window.close()
      UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    window.setFrameAutosaveName(name)
    window.setFrameOrigin(CGPoint(x: 120, y: 340))
    window.saveFrame(usingName: name)

    #expect(WindowCoordinator.hasSavedFrameForTesting(name))
  }
}
