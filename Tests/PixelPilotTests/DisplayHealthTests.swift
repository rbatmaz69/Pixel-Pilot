import AppKit
import PixelPilotCore
import SwiftUI
import Testing

@testable import PixelPilot

/// The full-screen overlay: getting out of it, marking in it, and leaving
/// nothing behind.
///
/// Built on the real controller with a real panel, like `OSDInteractionTests`,
/// because every failure worth catching here is the whole thing being assembled
/// correctly and still not working — a click that lands somewhere else, an
/// escape that leaves a mode instead of the screen, a repair session that keeps
/// the Mac awake after it ends.
@Suite("Display health overlay")
@MainActor
struct DisplayHealthTests {
  /// A dimmer that talks to nothing, so suspending a display in a test does not
  /// take the gamma tables off the machine running it.
  private struct SilentBackend: GammaDimmer.Backend {
    func applyRamps(
      red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue],
      to displayID: CGDirectDisplayID
    ) {}
    func restore(_ displayID: CGDirectDisplayID) {}
    func restoreAll() {}
  }

  private var screenID: CGDirectDisplayID? {
    (NSScreen.main ?? NSScreen.screens.first)?.displayID
  }

  private func controller() -> (DisplayHealthController, GammaDimmer) {
    let gamma = GammaDimmer(backend: SilentBackend())
    return (DisplayHealthController(gamma: gamma), gamma)
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  // MARK: - Getting out

  /// **The rule this suite exists for.** Escape means *leave the overlay* in
  /// every mode, never *leave this mode*. A full-screen panel whose only way
  /// out depends on which mode it happens to be in is a panel somebody is stuck
  /// inside.
  @Test("Escape leaves from every mode")
  func escapeAlwaysLeaves() throws {
    let id = try #require(screenID)

    for open in openers {
      let (health, _) = controller()
      open(health, id)
      #expect(health.isShowing, "the overlay never opened")
      health.handle(keyCode: 53)
      #expect(!health.isShowing, "escape did not leave from \(health.mode)")
    }
  }

  private var openers: [(DisplayHealthController, CGDirectDisplayID) -> Void] {
    [
      { health, id in health.showPatterns(on: id, named: "Probe") },
      { health, id in health.runHealthCheck(on: id, named: "Probe", defects: []) },
      { health, id in
        health.startMarking(on: id, named: "Probe", pattern: .black, defects: [])
      },
      { health, id in
        health.startRepair(
          on: id, named: "Probe",
          settings: .init(
            style: .noise, intensity: .gentle, duration: .tenMinutes, regions: []
          )
        )
      },
    ]
  }

  /// M toggles the mode. Escape out of marking still leaves the overlay rather
  /// than dropping back to browsing — which is the same rule stated from the
  /// other side, and the one easiest to break by making M and escape symmetric.
  @Test("M toggles marking, and escape out of it still leaves")
  func markingIsAMode() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    health.showPatterns(on: id, named: "Probe")
    #expect(health.mode == .browse)

    health.handle(keyCode: 46)
    #expect(health.mode == .marking)
    health.handle(keyCode: 46)
    #expect(health.mode == .browse)

    health.handle(keyCode: 46)
    health.handle(keyCode: 53)
    #expect(!health.isShowing)
  }

  /// Arrows change pattern while browsing and nudge while marking, which is the
  /// one place the key map differs between modes.
  @Test("Arrows step the pattern while browsing and not while marking")
  func arrowsChangeMeaning() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    health.showPatterns(on: id, named: "Probe")
    #expect(health.pattern == .white)
    health.handle(keyCode: 124)
    #expect(health.pattern == .black)

    health.handle(keyCode: 46)
    health.handle(keyCode: 124)
    #expect(health.pattern == .black, "an arrow while marking must not change pattern")
  }

  // MARK: - Marking

  /// The one that catches a top-left/bottom-left flip — the mistake
  /// `DisplayLayout` exists because of. A click three quarters of the way down
  /// the view has to store a mark three quarters of the way down the display,
  /// not one quarter.
  @Test("A click lands where it was clicked")
  func clickLandsWhereClicked() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startMarking(on: id, named: "Probe", pattern: .black, defects: [])

    let size = CGSize(width: 1000, height: 800)
    health.mark(at: CGPoint(x: 250, y: 600), viewSize: size, scale: 2)

    let mark = try #require(reported.first)
    #expect(abs(mark.region.midX - 0.25) < 0.01)
    #expect(abs(mark.region.midY - 0.75) < 0.01)
    // Spotted on black means something is lit that should not be.
    #expect(mark.kind == .stuck)
    #expect(mark.pattern == .black)
  }

  @Test("Clicking a mark again removes it")
  func clickingAMarkRemovesIt() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startMarking(on: id, named: "Probe", pattern: .black, defects: [])

    let size = CGSize(width: 1000, height: 800)
    health.mark(at: CGPoint(x: 500, y: 400), viewSize: size, scale: 2)
    #expect(reported.count == 1)

    health.mark(at: CGPoint(x: 502, y: 402), viewSize: size, scale: 2)
    #expect(reported.isEmpty, "the second click on the same spot must remove it")
  }

  @Test("A drag records a region rather than a spot")
  func dragRecordsARegion() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startMarking(on: id, named: "Probe", pattern: .black, defects: [])

    health.markRegion(
      CGRect(x: 100, y: 200, width: 300, height: 200),
      viewSize: CGSize(width: 1000, height: 800)
    )

    let mark = try #require(reported.first)
    #expect(abs(mark.region.x - 0.1) < 1e-9)
    #expect(abs(mark.region.width - 0.3) < 1e-9)
    #expect(abs(mark.region.height - 0.25) < 1e-9)
  }

  /// **Marking has to be reachable with the mouse alone.** The first version put
  /// it entirely behind `M`, which is fine once you know and invisible until
  /// you do — and "I want to mark the bad pixels with the mouse" was the first
  /// thing asked for after using it.
  ///
  /// A drag is the answer because nobody drags a box across a screen meaning
  /// *show me the next picture*, so it can mean "mark this" in every mode
  /// without ever colliding with what a click does.
  @Test("A drag marks in every mode, without entering one")
  func dragMarksWithoutAMode() throws {
    let id = try #require(screenID)
    let size = CGSize(width: 1000, height: 800)

    for open in [openers[0], openers[1]] {
      let (health, _) = controller()
      var reported: [PixelDefect] = []
      health.onDefectsChanged = { reported = $0 }
      open(health, id)

      #expect(health.mode != .marking, "this is meant to work without the mode")
      health.markRegion(CGRect(x: 100, y: 200, width: 300, height: 200), viewSize: size)
      #expect(reported.count == 1, "a drag in \(health.mode) marked nothing")
      health.hide()
    }
  }

  /// Drawing a box round something during a check *is* saying that pattern
  /// looked wrong. Leaving somebody to mark a defect and then separately answer
  /// that the screen looked fine would produce a report contradicting its own
  /// marks.
  @Test("Marking during a check records the problem, without moving on")
  func markingDuringACheckIsAnAnswer() throws {
    let id = try #require(screenID)
    let (health, _) = controller()

    var report: HealthReport?
    health.onReport = { report = $0 }
    health.runHealthCheck(on: id, named: "Probe", defects: [])
    health.handle(keyCode: 49)
    #expect(health.pattern == .black)

    health.markRegion(
      CGRect(x: 10, y: 10, width: 50, height: 50), viewSize: CGSize(width: 1000, height: 800)
    )
    // Still on the same pattern: the marking and the answer happen on one screen.
    #expect(health.pattern == .black)

    health.handle(keyCode: 53)
    let partial = try #require(report)
    #expect(partial[.black] == .problem)
    #expect(partial.defectCount == 1)
    #expect(partial.overall == .faults)
  }

  /// The buttons on the plate do the same as `M` and `H`, because a feature
  /// whose only door is a letter key is one most people never find.
  @Test("The plate's buttons reach marking and the plate itself")
  func buttonsMatchTheKeys() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    health.showPatterns(on: id, named: "Probe")
    health.toggleMarking()
    #expect(health.mode == .marking)
    health.toggleMarking()
    #expect(health.mode == .browse)

    // Hiding the plate with the mouse and only being able to bring it back with
    // a key would be a one-way door.
    health.togglePlate()
    health.togglePlate()
    #expect(health.isShowing)
  }

  /// A drag during a repair or over the summary is not a mark. There is no
  /// pattern under it to have found anything on.
  @Test("A drag marks nothing where there is nothing to mark")
  func dragIsInertWhereItShouldBe() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startRepair(
      on: id, named: "Probe",
      settings: .init(style: .noise, intensity: .gentle, duration: .tenMinutes, regions: [])
    )
    health.markRegion(
      CGRect(x: 10, y: 10, width: 50, height: 50), viewSize: CGSize(width: 1000, height: 800)
    )
    #expect(reported.isEmpty)
    #expect(health.mode == .repairing)
  }

  @Test("S and D correct the last mark's kind, and backspace removes it")
  func correctingAndRemoving() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startMarking(on: id, named: "Probe", pattern: .black, defects: [])
    health.mark(at: CGPoint(x: 500, y: 400), viewSize: CGSize(width: 1000, height: 800), scale: 2)

    health.handle(keyCode: 2)
    #expect(reported.first?.kind == .dead)
    health.handle(keyCode: 1)
    #expect(reported.first?.kind == .stuck)

    health.handle(keyCode: 51)
    #expect(reported.isEmpty)
  }

  /// Marks arrive already placed and are handed back complete, so opening the
  /// overlay to look at them and pressing escape cannot lose them.
  @Test("Existing marks come back out with the new ones")
  func existingMarksSurvive() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    let existing = PixelDefect(
      region: NormalisedRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01),
      kind: .dead,
      spottedOn: .white
    )

    var reported: [PixelDefect] = []
    health.onDefectsChanged = { reported = $0 }
    health.startMarking(on: id, named: "Probe", pattern: .black, defects: [existing])
    health.mark(at: CGPoint(x: 800, y: 700), viewSize: CGSize(width: 1000, height: 800), scale: 2)

    #expect(reported.count == 2)
    #expect(reported.contains { $0.id == existing.id })
  }

  // MARK: - The guided check

  @Test("Answering every pattern produces a complete report")
  func fullWalkReports() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    var report: HealthReport?
    health.onReport = { report = $0 }
    health.runHealthCheck(on: id, named: "Probe", defects: [])

    for _ in TestPattern.allCases {
      health.handle(keyCode: 49)
    }

    let finished = try #require(report)
    #expect(finished.isComplete)
    #expect(finished.overall == .clean)
    // The summary follows the walk rather than the overlay closing on its own:
    // eleven full-screen patterns and then the desktop would be no ending.
    #expect(health.mode == .summary)
    #expect(health.isShowing)
  }

  /// The whole integration: the moment you see the speck is the moment to mark
  /// it, not two screens later.
  @Test("N records a problem and drops straight into marking")
  func problemDropsIntoMarking() throws {
    let id = try #require(screenID)
    let (health, _) = controller()
    defer { health.hide() }

    health.runHealthCheck(on: id, named: "Probe", defects: [])
    health.handle(keyCode: 49)
    #expect(health.pattern == .black)

    health.handle(keyCode: 45)
    #expect(health.mode == .marking)
    #expect(health.pattern == .black, "marking happens on the pattern it was spotted on")

    // And M returns to the walk rather than to browsing, so the check can be
    // finished.
    health.handle(keyCode: 46)
    #expect(health.mode == .check)
  }

  /// A click during a check is an answer, not a page turn.
  ///
  /// The same surface means "next pattern" while browsing and "looks right"
  /// during a check, and if it kept meaning the first the walk would fall one
  /// step behind the screen — the plate would count a pattern nobody was
  /// looking at, and the report would record verdicts against the wrong ones.
  @Test("Clicking through a check answers it rather than only turning the page")
  func clickingIsAnAnswer() throws {
    let id = try #require(screenID)
    let (health, _) = controller()

    var report: HealthReport?
    health.onReport = { report = $0 }
    health.runHealthCheck(on: id, named: "Probe", defects: [])

    // Exactly what the view's tap gesture calls.
    for _ in TestPattern.allCases {
      health.advance()
    }

    let finished = try #require(report, "clicking through never produced a report")
    #expect(finished.isComplete)
    #expect(health.mode == .summary)
    health.hide()
  }

  /// Leaving never costs anything, which is what makes "escape always leaves"
  /// affordable.
  @Test("Leaving a check part-way still records what was answered")
  func abandonedCheckIsStillRecorded() throws {
    let id = try #require(screenID)
    let (health, _) = controller()

    var report: HealthReport?
    health.onReport = { report = $0 }
    health.runHealthCheck(on: id, named: "Probe", defects: [])
    health.handle(keyCode: 49)
    health.handle(keyCode: 49)
    health.handle(keyCode: 53)

    let partial = try #require(report)
    #expect(partial.answered.count == 2)
    #expect(partial.overall == .incomplete)
    // Skipped rather than absent: "stopped after two" and "answered two of
    // eleven" are the same statement.
    #expect(partial.verdicts.count == TestPattern.allCases.count)
  }

  @Test("Leaving before answering anything records nothing")
  func immediateEscapeRecordsNothing() throws {
    let id = try #require(screenID)
    let (health, _) = controller()

    var reports = 0
    health.onReport = { _ in reports += 1 }
    health.runHealthCheck(on: id, named: "Probe", defects: [])
    health.handle(keyCode: 53)

    #expect(reports == 0, "a check nobody answered is not a result")
  }

  // MARK: - Teardown

  /// Dropping the content view drops the SwiftUI hierarchy rather than leaving
  /// it standing, and the gamma tables go back on the display — every other
  /// overlay in this app makes the same two promises.
  @Test("Hiding puts the display back and drops the view")
  func teardownIsClean() throws {
    let id = try #require(screenID)
    let (health, gamma) = controller()

    health.showPatterns(on: id, named: "Probe")
    #expect(gamma.isSuspended(id), "the app's own tables must come off while this is up")

    health.hide()
    #expect(!gamma.isSuspended(id))
    #expect(!health.isShowing)
    #expect(health.mode == .browse)
    #expect(health.defects.isEmpty)
  }

  /// The path with the most to leak: a deadline task, a sleep assertion, and a
  /// running animation.
  @Test("A repair session leaves nothing running")
  func repairTeardownIsClean() throws {
    let id = try #require(screenID)
    let (health, gamma) = controller()

    health.startRepair(
      on: id, named: "Probe",
      settings: .init(
        style: .noise, intensity: .gentle, duration: .tenMinutes, regions: []
      )
    )
    #expect(health.mode == .repairing)
    #expect(gamma.isSuspended(id))
    settle(0.3)

    health.hide()
    #expect(!gamma.isSuspended(id))
    #expect(health.repairEndsAt == nil, "the deadline outlived the session")
    // A leaked activity assertion is a Mac that never sleeps again until quit,
    // so the deadline that would have fired against a torn-down panel must be
    // gone too. Given a moment to fire if it were still alive.
    settle(0.3)
    #expect(!health.isShowing)
  }

  /// Without this, unplugging a monitor mid-session leaves a panel on a screen
  /// that no longer exists — and, during a repair, the Mac awake for it.
  @Test("A display going away takes its overlay with it")
  func unpluggingClosesTheOverlay() throws {
    let id = try #require(screenID)
    let (health, gamma) = controller()
    defer { health.hide() }

    health.showPatterns(on: id, named: "Probe")
    // A reconfiguration that still has this display changes nothing.
    health.displaysChanged(online: [id])
    #expect(health.isShowing)

    health.displaysChanged(online: [id &+ 1])
    #expect(!health.isShowing)
    #expect(!gamma.isSuspended(id))
  }

  /// Opening a second time goes through the same teardown rather than replacing
  /// the panel underneath — otherwise the first display is left suspended.
  @Test("Reopening does not leave the first session behind")
  func reopeningIsClean() throws {
    let id = try #require(screenID)
    let (health, gamma) = controller()
    defer { health.hide() }

    health.startRepair(
      on: id, named: "Probe",
      settings: .init(
        style: .classic, intensity: .gentle, duration: .oneHour, regions: []
      )
    )
    health.showPatterns(on: id, named: "Probe")

    #expect(health.mode == .browse)
    #expect(health.repairEndsAt == nil, "the old session's deadline is still armed")
    #expect(gamma.isSuspended(id), "and the new session still suspends the display")
  }
}

/// The patterns as pixels.
///
/// Written after the checkerboard took the app to 32 GB and had to be killed
/// from Activity Monitor. It was a `Canvas` filling one `Path` per device pixel
/// — 4.1 million of them on a 4K panel, into a display list that was then
/// retained, measured at 1.1 GB for a *single* render and another gigabyte for
/// every re-render after it. It is the last pattern in the walk, so finishing a
/// health check was the way to find it.
///
/// Both halves are pinned here, because either one alone is satisfied by a bug:
/// a pattern that renders nothing costs no memory, and a pattern that costs no
/// memory may be drawing nothing.
private struct QuietBackend: GammaDimmer.Backend {
  func applyRamps(
    red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue],
    to displayID: CGDirectDisplayID
  ) {}
  func restore(_ displayID: CGDirectDisplayID) {}
  func restoreAll() {}
}

@Suite("Patterns as pixels")
@MainActor
struct TestPatternRenderTests {
  private func image(_ pattern: TestPattern, points: CGFloat, scale: CGFloat) -> CGImage? {
    let view = TestPatternView(
      pattern: pattern, displayName: "Probe", index: 0, total: 11,
      mode: .browse, defects: [], isPlateHidden: true, checkProgress: nil,
      onNext: {}, onPrevious: {}, onMark: { _, _, _ in }, onMarkRegion: { _, _ in },
      onToggleMarking: {}, onTogglePlate: {}, onClose: {}
    )
    .frame(width: points, height: points)
    .environment(\.displayScale, scale)

    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    return renderer.cgImage
  }

  /// Reads a rendered pattern back as the red channel of each device pixel.
  private func samples(_ image: CGImage) throws -> [Int] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0 ..< image.width * image.height).map { Int(pixels[$0 * 4]) }
  }

  private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : -1
  }

  /// One device pixel, not one point: on a Retina panel a one-point
  /// checkerboard is a two-pixel one, and a two-pixel checkerboard is visible
  /// at native resolution — so the pattern would report every display as being
  /// scaled.
  @Test("The checkerboard alternates every single device pixel")
  func checkerboardIsExact() throws {
    let scale: CGFloat = 2
    let rendered = try #require(image(.checkerboard, points: 20, scale: scale))
    #expect(rendered.width == 40)

    let values = try samples(rendered)

    // Nothing between black and white anywhere. A smoothed checkerboard reads
    // as flat grey, which is what "not being scaled" looks like — so an
    // interpolated pattern is one that always passes.
    #expect(Set(values) == [0, 255])

    // Half of each, which only holds if the alternation is exact.
    let mean = Double(values.reduce(0, +)) / Double(values.count)
    #expect(abs(mean - 127.5) < 0.01)

    // And the alternation is in both directions, not stripes.
    let width = rendered.width
    for y in 0 ..< 4 {
      for x in 0 ..< 4 {
        let here = values[y * width + x]
        #expect(values[y * width + x + 1] != here, "no alternation across")
        #expect(values[(y + 1) * width + x] != here, "no alternation down")
      }
    }
  }

  /// The regression, measured the way the app actually meets it: a real panel
  /// on the checkerboard, with marks placed one after another.
  ///
  /// This is what the person who hit it was doing — finishing a walk, which
  /// ends on the checkerboard, and then looking around and marking. Every mark
  /// re-renders the overlay, and the original leaked a gigabyte on each one.
  /// Measures about **1 MB for sixty marks**.
  @Test("Marking on the checkerboard does not grow the app")
  func liveMarkingIsCheap() throws {
    let id = try #require((NSScreen.main ?? NSScreen.screens.first)?.displayID)
    let live = DisplayHealthController(gamma: GammaDimmer(backend: QuietBackend()))
    defer { live.hide() }

    live.startMarking(on: id, named: "Probe", pattern: .checkerboard, defects: [])
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    let before = footprintMB()
    for step in 0 ..< 60 {
      live.mark(
        at: CGPoint(x: 10 + Double(step) * 7, y: 40),
        viewSize: CGSize(width: 1000, height: 800),
        scale: 2
      )
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let growth = footprintMB() - before

    #expect(growth < 60, "sixty marks grew the footprint by \(Int(growth)) MB")
  }

  /// The same claim from the other side, and stated as a ratio on purpose.
  ///
  /// Rendering to a fresh bitmap at 4K allocates on every pass whatever is
  /// being drawn — about 15 MB a render here, all of it the harness rather than
  /// the app, which is why the absolute number is worthless as a threshold and
  /// why the test above measures the live path instead. What *is* worth
  /// asserting is that the checkerboard costs no more than a flat colour. With
  /// the bug it cost 1088 MB against 15, so this fails by seventy times over
  /// rather than by a few percent.
  @Test("The checkerboard costs no more to draw than a solid colour")
  func checkerboardIsNoWorseThanASolid() throws {
    // Warm up on both, so first-render setup lands outside the measurement.
    _ = image(.white, points: 1920, scale: 2)
    _ = image(.checkerboard, points: 1920, scale: 2)

    let beforeSolid = footprintMB()
    for _ in 0 ..< 10 { _ = image(.white, points: 1920, scale: 2) }
    let solid = footprintMB() - beforeSolid

    let beforeChecker = footprintMB()
    for _ in 0 ..< 10 { _ = image(.checkerboard, points: 1920, scale: 2) }
    let checker = footprintMB() - beforeChecker

    #expect(
      checker < max(solid, 20) * 3,
      "the checkerboard cost \(Int(checker)) MB against a solid colour's \(Int(solid))"
    )
  }
}

/// The exerciser itself.
///
/// Everything in the suite above is about getting into and out of the overlay.
/// This is about whether the thing it opens actually does anything — a repair
/// pass that ran for ten minutes and exercised nothing would pass every test
/// there is up to here, and would look right on screen.
@Suite("Exercising")
@MainActor
struct RepairSurfaceTests {
  private func view(
    style: RepairPlan.Style = .noise,
    intensity: RepairPlan.Intensity = .standard,
    regions: [NormalisedRect] = [],
    refreshHz: Double = 60
  ) -> RepairLayerView {
    let view = RepairLayerView()
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
    view.install(
      settings: .init(
        style: style, intensity: intensity, duration: .tenMinutes, regions: regions
      ),
      refreshHz: refreshHz
    )
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func animation(_ layer: CALayer) throws -> CAKeyframeAnimation {
    try #require(layer.animation(forKey: "exercise") as? CAKeyframeAnimation)
  }

  /// **The single assertion that decides whether the feature works.** Bilinear
  /// magnification averages neighbouring cells toward mid grey, which destroys
  /// the per-pixel swing that is the entire point — the screen would look busy
  /// and exercise nothing.
  @Test("The noise is magnified without being averaged away")
  func noiseIsNotSmoothed() throws {
    let layer = try #require(view().layer?.sublayers?.first)
    #expect(layer.magnificationFilter == .nearest)
    #expect(layer.minificationFilter == .nearest)
    #expect(layer.contents != nil, "no field was ever put on the layer")
  }

  /// Discrete rather than interpolated: a cross-fade between two cube corners
  /// spends most of its time in the middle, which is where a cell is not being
  /// worked at all.
  @Test("The fields are switched, not blended")
  func fieldsAreDiscrete() throws {
    let layer = try #require(view().layer?.sublayers?.first)
    let keyframes = try animation(layer)
    #expect(keyframes.calculationMode == .discrete)
    #expect(keyframes.values?.count == 32)
    #expect(keyframes.repeatCount > 1_000_000, "the exercise stops after one cycle")
    // 32 fields at 60 Hz — a panel cannot show more transitions than it
    // refreshes, so this is the honest ceiling rather than a preference.
    #expect(abs(keyframes.duration - 32.0 / 60) < 1e-6)
  }

  @Test("A faster panel is exercised faster, a gentle pass is not")
  func rateFollowsThePanel() throws {
    let fast = try animation(#require(view(refreshHz: 120).layer?.sublayers?.first))
    #expect(abs(fast.duration - 32.0 / 120) < 1e-6)

    let gentle = try animation(
      #require(view(intensity: .gentle, refreshHz: 120).layer?.sublayers?.first)
    )
    // Three a second is the WCAG line, and it does not move because the panel
    // can go faster.
    #expect(abs(gentle.duration - 32.0 / 3) < 1e-6)
  }

  /// Neighbouring marks flashing in lockstep would be a small local flash,
  /// which is the one thing the whole design is avoiding.
  @Test("Marked regions get one layer each, out of phase with each other")
  func regionsAreOutOfPhase() throws {
    let regions = [
      NormalisedRect(x: 0.2, y: 0.3, width: 0.05, height: 0.05),
      NormalisedRect(x: 0.6, y: 0.5, width: 0.05, height: 0.05),
    ]
    let layers = try #require(view(regions: regions).layer?.sublayers)
    #expect(layers.count == 2)

    let first = try animation(layers[0]).values?.first
    let second = try animation(layers[1]).values?.first
    #expect(
      String(describing: first) != String(describing: second),
      "both regions start on the same colour"
    )

    // And each one is where its mark is, rather than all at the origin.
    #expect(abs(layers[0].frame.minX - 0.2 * 800) < 1e-6)
    #expect(abs(layers[1].frame.minY - 0.5 * 500) < 1e-6)
  }

  @Test("Tearing down stops everything and leaves no layers")
  func teardownStops() throws {
    let view = view()
    #expect(view.layer?.sublayers?.isEmpty == false)
    view.teardown()
    #expect(view.layer?.sublayers?.isEmpty != false)
  }

  /// The pre-rendered fields are the one deliberately large allocation in this
  /// app — 32 of them at 480×270, about 16 MB — and they are worth pinning at
  /// both ends: large enough to be worth measuring, and bounded so that opening
  /// and closing the overlay repeatedly does not accumulate.
  ///
  /// Measured because the checkerboard bug next door was exactly this shape and
  /// was not caught by anything until a machine had 32 GB in Activity Monitor.
  @Test("Repeated sessions do not accumulate")
  func sessionsDoNotAccumulate() {
    func footprintMB() -> Double {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
      )
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : -1
    }

    // The first session pays for the fields; what is being measured is whether
    // the ones after it pay again.
    autoreleasepool { _ = view() }
    let before = footprintMB()

    for _ in 0 ..< 8 {
      autoreleasepool {
        let session = view()
        session.teardown()
      }
    }

    let growth = footprintMB() - before
    // Eight more sessions at the full 16 MB each would be 128 MB. Measured at
    // roughly 14, which is the allocator holding freed pages rather than the
    // fields being kept.
    #expect(growth < 60, "eight repair sessions grew the footprint by \(Int(growth)) MB")
  }
}

/// The drag rectangle.
///
/// A drag that goes up and to the left is as valid as one that goes down and to
/// the right, and a negative width is neither drawable nor storable — the
/// `NormalisedRect` clamp would quietly turn it into the minimum square at the
/// origin, which is a mark in the wrong place rather than a visible failure.
@Suite("Marking a region")
struct MarkRegionTests {
  @Test("A drag makes the same rectangle in every direction")
  func dragDirectionDoesNotMatter() {
    let topLeft = CGPoint(x: 100, y: 100)
    let bottomRight = CGPoint(x: 300, y: 250)
    let expected = CGRect(x: 100, y: 100, width: 200, height: 150)

    #expect(CGRect(from: topLeft, to: bottomRight) == expected)
    #expect(CGRect(from: bottomRight, to: topLeft) == expected)
    #expect(
      CGRect(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 100, y: 250)) == expected
    )
  }

  @Test("A drag that goes nowhere has no size")
  func zeroDrag() {
    let point = CGPoint(x: 50, y: 50)
    #expect(CGRect(from: point, to: point) == CGRect(x: 50, y: 50, width: 0, height: 0))
  }
}
