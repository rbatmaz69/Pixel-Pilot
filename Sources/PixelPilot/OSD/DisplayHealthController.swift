import AppKit
import PixelPilotCore
import SwiftUI

/// Everything that happens full-screen on one display: the test patterns, the
/// guided check, marking bad pixels, and the repair pass.
///
/// Built from the same `OverlayPanel` as the HUD and the identify overlay, and
/// structured like `IdentifyController` — but with three deliberate differences
/// from it, each of which is a rule that file states being broken on purpose:
///
/// **It stays.** No dismiss task. Looking for a dead pixel takes as long as it
/// takes, and a repair pass takes ten minutes.
///
/// **It takes the keyboard and the mouse.** `OverlayPanel` argues against a
/// full-screen panel accepting events, correctly, for an overlay nobody asked
/// for. This one was opened deliberately and the only real failure is being
/// unable to leave, so Escape has to arrive somewhere.
///
/// **It takes the app's own tables off the display.** A banding test seen
/// through a lifted tone curve is a statement about the tone curve. `suspend`
/// rather than `clear` because the warmth and finish have to come back
/// afterwards, and only the dimmer still knows what they were.
///
/// **Why one controller for four modes.** A panel wants exactly one owner —
/// the argument `IdentifyController` already makes about the HUD. All four
/// target the same display, need the same suspend/resume pair, the same key
/// monitor and the same teardown, and they transition into each other: `N`
/// during a check drops straight into marking, and the summary follows the
/// check. Splitting them would mean two `hide()` calls to remember in
/// `AppModel.stop()` and two chances to leave a display suspended.
@MainActor
final class DisplayHealthController {
  /// What the overlay is currently for.
  ///
  /// `browse` is what this controller did before it had any others, and it is
  /// unchanged: the Diagnostics button still opens exactly what it used to.
  enum Mode: Equatable {
    case browse
    case marking
    case check
    /// The walk is over and the verdict is on screen.
    case summary
    case repairing
  }

  private(set) var mode: Mode = .browse
  private(set) var pattern: TestPattern = .white
  private(set) var defects: [PixelDefect] = []

  private var panel: NSPanel?
  private var displayID: CGDirectDisplayID?
  private var displayName = ""
  private var keyMonitor: Any?
  private var session: HealthCheckSession?
  private var isPlateHidden = false

  /// The repair session's own state. Nothing else uses these, and they are the
  /// two things in this class whose leak is worse than a stale view.
  private var repair: RepairSettings?
  private var repairDeadline: Task<Void, Never>?
  private(set) var repairEndsAt: Date?
  private var sleepAssertion: (any NSObjectProtocol)?

  /// Callbacks rather than a reference to the view model, matching how
  /// `AttentionController` takes its candidate list: this owns a panel, not a
  /// display's settings. It also has to be this way — `AppModel.refresh()`
  /// recreates every `DisplayViewModel`, so anything captured once at
  /// construction would be writing to a dead one by the second reconnect.
  var onDefectsChanged: (([PixelDefect]) -> Void)?
  var onReport: ((HealthReport) -> Void)?

  private let gamma: GammaDimmer

  init(gamma: GammaDimmer = .shared) {
    self.gamma = gamma
  }

  var isShowing: Bool { panel != nil }

  struct RepairSettings: Equatable {
    var style: RepairPlan.Style
    var intensity: RepairPlan.Intensity
    var duration: RepairPlan.Duration
    var regions: [NormalisedRect]
  }

  // MARK: - Opening

  /// The test patterns, as they have always been.
  func showPatterns(
    on displayID: CGDirectDisplayID, named name: String, defects: [PixelDefect] = []
  ) {
    open(on: displayID, named: name, defects: defects, mode: .browse, pattern: .white)
  }

  /// The guided walk.
  func runHealthCheck(
    on displayID: CGDirectDisplayID, named name: String, defects: [PixelDefect]
  ) {
    let walk = HealthCheckSession()
    open(
      on: displayID, named: name, defects: defects, mode: .check,
      pattern: walk.current ?? .white, session: walk
    )
  }

  /// Straight into marking, on the pattern the marks can actually be seen
  /// against.
  func startMarking(
    on displayID: CGDirectDisplayID,
    named name: String,
    pattern: TestPattern,
    defects: [PixelDefect]
  ) {
    open(on: displayID, named: name, defects: defects, mode: .marking, pattern: pattern)
  }

  func startRepair(
    on displayID: CGDirectDisplayID, named name: String, settings: RepairSettings
  ) {
    open(
      on: displayID, named: name, defects: [], mode: .repairing, pattern: .black,
      repair: settings
    )
    guard isShowing else { return }
    beginRepairSession(settings)
  }

  private func open(
    on displayID: CGDirectDisplayID,
    named name: String,
    defects: [PixelDefect],
    mode: Mode,
    pattern: TestPattern,
    repair: RepairSettings? = nil,
    session: HealthCheckSession? = nil
  ) {
    // Whatever was up goes first, through the same teardown as always — so the
    // gamma tables, the monitor and any running repair come off cleanly rather
    // than being replaced underneath. Which is also why the new session's state
    // arrives as parameters rather than as fields set beforehand: `hide()`
    // clears every field this object has, deliberately and without exception,
    // so anything set before this line is set for one statement only.
    hide()

    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }

    self.repair = repair
    self.session = session
    self.displayID = displayID
    displayName = name
    self.defects = defects
    self.mode = mode
    self.pattern = pattern
    isPlateHidden = false
    gamma.suspend(displayID)

    let made = OverlayPanel.make(
      content: AnyView(EmptyView()), acceptsMouse: true, canBecomeKey: true
    )
    made.panel.setFrame(screen.frame, display: false)
    panel = made.panel
    render()

    made.panel.alphaValue = 1
    made.panel.makeKeyAndOrderFront(nil)
    // A background app's window does not come forward on its own. This is the
    // one place the app activates, and it is what makes Escape reach us.
    NSApp.activate(ignoringOtherApps: true)

    // Escape as well as the panel's own key handling: a SwiftUI `onKeyPress`
    // inside a borderless panel is at the mercy of what has first responder,
    // and the way out of a full-screen overlay is the one thing that cannot be
    // allowed to depend on that.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isShowing else { return event }
      return self.handle(keyCode: event.keyCode) ? nil : event
    }
  }

  // MARK: - Closing

  /// The one teardown, and the order is load-bearing throughout.
  func hide() {
    // First, so nothing can render into a panel that is being taken apart, and
    // so a ten-minute deadline cannot fire against a display that has gone.
    repairDeadline?.cancel()
    repairDeadline = nil
    repairEndsAt = nil
    // A leaked activity assertion is a Mac that never sleeps again until the
    // app is quit. It goes here, above every early return, and there are none
    // below it.
    if let sleepAssertion {
      ProcessInfo.processInfo.endActivity(sleepAssertion)
    }
    sleepAssertion = nil
    repair = nil

    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
    keyMonitor = nil

    // Before the panel goes, so the display is never briefly showing the
    // desktop with our tables still off it.
    if let displayID {
      gamma.resume(displayID)
    }
    displayID = nil

    panel?.orderOut(nil)
    // Same reason as everywhere else in this app: dropping the content view
    // drops the SwiftUI hierarchy rather than leaving it standing.
    panel?.contentView = nil
    panel = nil

    mode = .browse
    session = nil
    defects = []
    isPlateHidden = false
  }

  /// A display that has gone away takes its overlay with it.
  ///
  /// Without this, unplugging a monitor mid-session leaves a panel positioned
  /// on a screen that no longer exists — and, since the repair pass holds a
  /// sleep assertion, keeps the Mac awake for a display nobody can see. The
  /// controller this grew out of has always had the first half of that.
  func displaysChanged(online: Set<CGDirectDisplayID>) {
    guard let displayID, !online.contains(displayID) else { return }
    hide()
  }

  // MARK: - Keys

  /// Split out of the event monitor so every mode's way out can be tested
  /// without an event tap. Returns whether the key was ours to swallow.
  ///
  /// **Escape is inviolable.** In every mode it means *leave the overlay*,
  /// never *leave this mode*. That is affordable only because marks are
  /// persisted the instant they are placed, so escape is never destructive —
  /// and the two rules have to stay true together.
  @discardableResult
  func handle(keyCode: UInt16) -> Bool {
    guard isShowing else { return false }

    if keyCode == Key.escape {
      // Leaving a check part-way is still an answer, so it is written before
      // the session goes. This is what makes the "escape always leaves the
      // overlay" rule affordable: leaving never costs anything.
      finishCheckEarly()
      hide()
      return true
    }

    switch mode {
    case .browse: return handleBrowse(keyCode)
    case .marking: return handleMarking(keyCode)
    case .check: return handleCheck(keyCode)
    case .summary: return false
    case .repairing: return false
    }
  }

  private func handleBrowse(_ keyCode: UInt16) -> Bool {
    switch keyCode {
    case Key.left: step(-1); return true
    case Key.right, Key.space: step(1); return true
    case Key.m: enterMarking(); return true
    case Key.h: togglePlate(); return true
    default: return false
    }
  }

  private func handleMarking(_ keyCode: UInt16) -> Bool {
    switch keyCode {
    // Arrows nudge rather than change pattern, which is the one place this
    // overlay's key map is not consistent across modes. Hitting a single pixel
    // with a mouse is genuinely hard, and this is the cheapest precision
    // available without a loupe — a loupe would need screen-recording
    // permission, which this app does not ask for and should not start asking
    // for over a marker. Changing pattern means leaving mark mode; the plate
    // says so.
    case Key.left: nudgeLast(dx: -1, dy: 0); return true
    case Key.right: nudgeLast(dx: 1, dy: 0); return true
    case Key.up: nudgeLast(dx: 0, dy: -1); return true
    case Key.down: nudgeLast(dx: 0, dy: 1); return true
    case Key.s: reclassifyLast(.stuck); return true
    case Key.d: reclassifyLast(.dead); return true
    case Key.delete: removeLast(); return true
    case Key.h: togglePlate(); return true
    case Key.m, Key.enter: leaveMarking(); return true
    default: return false
    }
  }

  private func handleCheck(_ keyCode: UInt16) -> Bool {
    switch keyCode {
    case Key.space, Key.y: answer(.looksRight); return true
    // Straight into marking, and this is the whole integration: the moment you
    // see the speck is the moment to mark it, not two screens later.
    case Key.n:
      session?.flagCurrent()
      enterMarking()
      return true
    case Key.left: goBack(); return true
    case Key.m: enterMarking(); return true
    case Key.h: togglePlate(); return true
    default: return false
    }
  }

  /// Carbon key codes. Named because `case 123` in four switch statements is
  /// four chances to get one wrong.
  private enum Key {
    static let enter: UInt16 = 36
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let delete: UInt16 = 51
    static let d: UInt16 = 2
    static let h: UInt16 = 4
    static let m: UInt16 = 46
    static let n: UInt16 = 45
    static let s: UInt16 = 1
    static let y: UInt16 = 16
  }

  // MARK: - Browsing

  /// What "next" means, which is not the same thing in both modes.
  ///
  /// Browsing, it is the next pattern. During a check it is an answer — the
  /// same one the space bar gives — because a click that moved the picture on
  /// without recording anything would leave the walk one step behind what is on
  /// the screen, and the plate would be counting a pattern nobody was looking
  /// at. Clicking is offered during a check precisely because it is the
  /// cheapest thing to do while staring at a screen.
  func advance() {
    if mode == .check {
      answer(.looksRight)
    } else {
      step(1)
    }
  }

  private func step(_ delta: Int) {
    let all = TestPattern.allCases
    guard let current = all.firstIndex(of: pattern) else { return }
    pattern = all[(current + delta + all.count) % all.count]
    render()
  }

  // MARK: - The guided check

  private func answer(_ verdict: HealthReport.PatternVerdict) {
    guard var session else { return }
    session.answer(verdict)
    self.session = session

    if let next = session.current {
      pattern = next
      render()
    } else {
      finishCheck()
    }
  }

  private func goBack() {
    guard var session else { return }
    session.back()
    self.session = session
    if let current = session.current {
      pattern = current
      render()
    }
  }

  /// The report is written on the way *into* the summary rather than on
  /// leaving it, so quitting from the summary — or unplugging the display while
  /// it is up — does not lose the answers.
  private func finishCheck() {
    guard let session else { return }
    onReport?(session.report(defectCount: defects.count))
    mode = .summary
    render()
  }

  /// Leaving early still writes what was answered, with the rest marked skipped
  /// rather than omitted. "Stopped after five" and "answered five of eleven"
  /// are the same statement.
  ///
  /// Not gated on the mode, because a check that dropped into marking is still
  /// a check — and that is exactly when somebody is most likely to give up and
  /// press escape.
  private func finishCheckEarly() {
    guard let session, !session.isFinished, !session.verdicts.isEmpty else { return }
    onReport?(session.report(defectCount: defects.count))
  }

  // MARK: - Marking

  private func enterMarking() {
    mode = .marking
    render()
  }

  /// Back to wherever marking was entered from. A check that dropped into
  /// marking resumes the walk; anything else goes back to browsing.
  private func leaveMarking() {
    mode = session?.isFinished == false ? .check : .browse
    render()
  }

  /// A click: place a mark, or remove the one already under the pointer.
  ///
  /// Both on the same gesture because they are the same intent — "this spot" —
  /// and because a separate delete gesture on a full-screen overlay is one more
  /// thing to have to know.
  func mark(at point: CGPoint, viewSize: CGSize, scale: CGFloat) {
    guard viewSize.width > 0, viewSize.height > 0 else { return }
    let normalised = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)

    if let existing = PixelDefects.hitTest(defects, at: normalised, tolerance: hitTolerance(viewSize)) {
      defects.removeAll { $0.id == existing.id }
    } else {
      let pixels = CGSize(width: viewSize.width * scale, height: viewSize.height * scale)
      defects.append(
        PixelDefect(
          region: .around(
            CGPoint(x: point.x * scale, y: point.y * scale),
            sidePixels: Self.markSidePixels,
            in: pixels
          ),
          kind: .likely(spottedOn: pattern),
          spottedOn: pattern
        )
      )
    }
    commitDefects()
  }

  /// A drag: a region rather than a spot, for backlight bleed and clouding —
  /// which are not one pixel and cannot honestly be marked as one.
  ///
  /// Accepted in **every** mode, which is what makes marking reachable with the
  /// mouse alone: nobody drags a box across a screen meaning "show me the next
  /// picture", so this can never collide with what a click does.
  func markRegion(_ rect: CGRect, viewSize: CGSize) {
    guard viewSize.width > 0, viewSize.height > 0 else { return }
    guard mode != .repairing, mode != .summary else { return }

    // Drawing a box round something during a check *is* saying that pattern
    // looked wrong, so it is recorded as such rather than leaving somebody to
    // mark a defect and then separately answer that the screen looked fine.
    // Without advancing: the marking and the answer happen on the same screen.
    if mode == .check {
      session?.flagCurrent()
    }

    defects.append(
      PixelDefect(
        region: .normalising(rect, in: viewSize),
        kind: .likely(spottedOn: pattern),
        spottedOn: pattern
      )
    )
    commitDefects()
  }

  /// Into and out of per-pixel marking, for the buttons on the plate.
  ///
  /// The same thing `M` does. It exists because a feature whose only door is a
  /// letter key is one most people never find — dragging a box needs no mode,
  /// but placing and removing single pixels does.
  func toggleMarking() {
    guard isShowing, mode != .repairing, mode != .summary else { return }
    if mode == .marking {
      leaveMarking()
    } else {
      enterMarking()
    }
  }

  /// Hides the plate, or brings it back. The same thing `H` does, and it needs
  /// a mouse route for the same reason — hiding it with a click and only being
  /// able to bring it back with a key is a one-way door.
  func togglePlate() {
    guard isShowing else { return }
    isPlateHidden.toggle()
    render()
  }

  private func nudgeLast(dx: Double, dy: Double) {
    guard var last = defects.last, let size = panelSize() else { return }
    let scale = panel?.backingScaleFactor ?? 2
    last.region = last.region.nudged(
      dx: dx / (size.width * scale),
      dy: dy / (size.height * scale)
    )
    defects[defects.count - 1] = last
    commitDefects()
  }

  private func reclassifyLast(_ kind: PixelDefect.Kind) {
    guard var last = defects.last else { return }
    last.kind = kind
    defects[defects.count - 1] = last
    commitDefects()
  }

  private func removeLast() {
    guard !defects.isEmpty else { return }
    defects.removeLast()
    commitDefects()
  }

  private func commitDefects() {
    onDefectsChanged?(defects)
    render()
  }

  /// A stored mark is a handful of device pixels across. Clicking one back
  /// again at that size is not realistic, so the tolerance is an order of
  /// magnitude larger than what is stored — store tight, hit generously.
  private func hitTolerance(_ viewSize: CGSize) -> Double {
    guard viewSize.width > 0 else { return 0 }
    return Self.hitTolerancePoints / viewSize.width
  }

  /// Six device pixels. Small enough to be a record of *where*, big enough that
  /// `NormalisedRect` does not have to round it to nothing.
  static let markSidePixels: Double = 6
  private static let hitTolerancePoints: Double = 12

  private func panelSize() -> CGSize? {
    panel?.contentView?.bounds.size
  }

  // MARK: - Repair

  private func beginRepairSession(_ settings: RepairSettings) {
    // Ten minutes of a display that macOS thinks nobody is looking at would
    // sleep four minutes in. The token is held on this object and released in
    // `hide()`, which is the only path out of here.
    sleepAssertion = ProcessInfo.processInfo.beginActivity(
      options: [.idleDisplaySleepDisabled, .userInitiated],
      reason: "Exercising stuck pixels"
    )

    guard let seconds = settings.duration.seconds else { return }
    let endsAt = Date().addingTimeInterval(seconds)
    repairEndsAt = endsAt
    render()

    // One sleep to the deadline, and nothing in between.
    //
    // The countdown on screen is the view's own business, deliberately: having
    // the controller re-render once a second to update it would hand SwiftUI a
    // fresh view every second, and every second is when a keyframe animation
    // that got rebuilt would restart from its first field. A ten-minute
    // exercise that keeps returning to black is not an exercise.
    repairDeadline = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  // MARK: - Rendering

  private func render() {
    guard let hosting = panel?.contentView as? NSHostingView<AnyView> else { return }

    if mode == .repairing, let repair {
      hosting.rootView = AnyView(
        RepairView(
          settings: repair,
          displayName: displayName,
          endsAt: repairEndsAt,
          refreshHz: refreshHz(),
          onStop: { [weak self] in self?.hide() }
        )
        .withMotionTokens()
      )
      return
    }

    if mode == .summary, let session {
      hosting.rootView = AnyView(
        HealthSummaryView(
          report: session.report(defectCount: defects.count),
          displayName: displayName,
          onClose: { [weak self] in self?.hide() }
        )
        .withMotionTokens()
      )
      return
    }

    let all = TestPattern.allCases
    hosting.rootView = AnyView(
      TestPatternView(
        pattern: pattern,
        displayName: displayName,
        index: all.firstIndex(of: pattern) ?? 0,
        total: all.count,
        mode: mode,
        defects: defects,
        isPlateHidden: isPlateHidden,
        checkProgress: session.map { ($0.progress.step, $0.progress.total) },
        onNext: { [weak self] in self?.advance() },
        onPrevious: { [weak self] in self?.step(-1) },
        onMark: { [weak self] point, size, scale in
          self?.mark(at: point, viewSize: size, scale: scale)
        },
        onMarkRegion: { [weak self] rect, size in self?.markRegion(rect, viewSize: size) },
        onToggleMarking: { [weak self] in self?.toggleMarking() },
        onTogglePlate: { [weak self] in self?.togglePlate() },
        onClose: { [weak self] in
          self?.finishCheckEarly()
          self?.hide()
        }
      )
      // No theme, unlike every other overlay. A test pattern tinted by the
      // app's accent colour would be testing the app.
      .withMotionTokens()
    )
  }

  /// What this particular panel can actually show, which is the honest ceiling
  /// on how fast a cell can be exercised.
  private func refreshHz() -> Double {
    guard let displayID,
      let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
    else { return 60 }
    let reported = Double(screen.maximumFramesPerSecond)
    return reported > 0 ? reported : 60
  }

  isolated deinit {
    // The check's answers are worth keeping even when the way out was the app
    // quitting. Before `hide()`, which drops the session.
    finishCheckEarly()
    hide()
  }
}
