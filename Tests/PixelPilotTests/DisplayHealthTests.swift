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
@Suite("Patterns as pixels")
@MainActor
struct TestPatternRenderTests {
  private func image(_ pattern: TestPattern, points: CGFloat, scale: CGFloat) -> CGImage? {
    let view = TestPatternView(
      pattern: pattern, displayName: "Probe", index: 0, total: 11,
      mode: .browse, defects: [], isPlateHidden: true, checkProgress: nil,
      onNext: {}, onPrevious: {}, onMark: { _, _, _ in }, onMarkRegion: { _, _ in },
      onClose: {}
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

  /// The regression itself, in the units the bug was reported in.
  ///
  /// Rendered at the size of a real 4K panel, which is where 4.1 million paths
  /// came from. Ten renders, because the original leaked a fresh gigabyte on
  /// each one and a single render would understate it.
  @Test("Rendering the patterns at 4K costs almost nothing")
  func renderingIsCheap() throws {
    // Warm up, so one-off allocations are not counted as the leak.
    _ = image(.checkerboard, points: 100, scale: 2)

    let before = footprintMB()
    for _ in 0 ..< 10 {
      _ = image(.checkerboard, points: 1920, scale: 2)
    }
    let growth = footprintMB() - before

    // The original measured +1088 MB for one render. A hundred is generous and
    // still two orders of magnitude away from the bug.
    #expect(growth < 100, "ten 4K renders grew the footprint by \(Int(growth)) MB")
  }

  /// The other patterns were never suspect, but they are the control: if the
  /// harness above measured nothing, this would pass too.
  @Test("A solid and a ramp are cheap, as they always were")
  func othersStayCheap() throws {
    for pattern in [TestPattern.white, .greyRamp, .shadowSteps] {
      let before = footprintMB()
      _ = image(pattern, points: 1920, scale: 2)
      #expect(footprintMB() - before < 100, "\(pattern.rawValue) is expensive to draw")
    }
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
