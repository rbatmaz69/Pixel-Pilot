import AppKit
import PixelPilotCore
import os

/// Pushes back the screens that are not being worked on.
///
/// Three parts, kept apart because they fail differently: `FocusedWindowScreen`
/// answers *which* screen, `AttentionPlan` decides *what each one gets*, and
/// this type is only the wiring between the events and the gamma tables. The
/// decision is in `PixelPilotCore` precisely so the cases that matter — nobody
/// focused, one display, a display opted out — are testable without
/// Accessibility, a window server or a second monitor.
///
/// What it writes is `GammaDimmer.setVeil`, never `setDimming`. That is the
/// whole reason the veil exists as its own term; see the comment on
/// `GammaDimmer.veils`.
@MainActor
final class AttentionController {
  private let preferences: Preferences
  private let gamma: GammaDimmer
  /// Which displays exist and whether each is willing to sink, asked for fresh
  /// each time rather than cached — displays come and go, and a stale list
  /// would leave a veil on a display nobody can see any more.
  private let candidates: () -> [AttentionPlan.Candidate]

  private let windowObserver = FocusedWindowObserver()

  /// Clicks anywhere outside this app.
  ///
  /// The third source, and the one that closes the gap the other two leave.
  /// Clicking a screen's desktop while the Finder is already frontmost sends no
  /// activation — it is already frontmost — and no focused-window change, since
  /// the Finder has no window. Clicking a window that is already the focused
  /// one of the already-frontmost application sends neither either. In both
  /// cases nothing at all arrives, and the screens sit where they were: "it
  /// works sometimes".
  ///
  /// This is not the pointer-following that was turned down. That needed
  /// `.mouseMoved`, which fires continuously for as long as a hand is on the
  /// mouse. `.leftMouseDown` fires when somebody decides something, at the rate
  /// people decide things, and a click is the plainest statement of where the
  /// attention just went.
  private var clickMonitor: Any?

  /// Rounds up bursts. Holding ⌘-Tab sends one activation per application
  /// passed through, and each would otherwise be a gamma write — the screens
  /// strobing through everything between here and where you were going.
  ///
  /// Shorter than the 200 ms the app rules use, because those cost a round of
  /// DDC writes and this costs one gamma table. Long enough to swallow a burst,
  /// short enough that a deliberate switch feels immediate.
  private let debouncer = Debouncer(delay: .milliseconds(120))

  private var isRunning = false

  /// One line per settled decision.
  ///
  /// This feature is a set of events nobody can see arriving, resolving to a
  /// display nobody can see chosen. When it does the wrong thing there is
  /// nothing on screen to reason from — "it felt like the monitor stayed the
  /// same" is the whole of the available evidence otherwise.
  ///
  /// `info` rather than `debug`, and that is not a preference: debug output
  /// lives in a memory buffer and never reaches disk, so `log show` after the
  /// fact finds nothing — which is exactly when it is wanted. The rate is human
  /// speed, one line per settled change, in the same register as the preset
  /// line the app rules already log.
  ///
  ///   log show --last 10m --info --predicate \
  ///     'subsystem == "dev.rb.pixelpilot" AND category == "attention"'
  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "attention")

  /// Which event source asked for the update currently settling. Carried into
  /// the log line, because "the app activation fired but the window one never
  /// did" is two completely different faults and is invisible from outside.
  private var lastReason = "start"
  /// Whether the AX registration on the frontmost app took. False degrades this
  /// to application-level granularity — silently, which is the problem.
  private var isWatchingWindows = false

  init(
    preferences: Preferences,
    gamma: GammaDimmer = .shared,
    candidates: @escaping () -> [AttentionPlan.Candidate]
  ) {
    self.preferences = preferences
    self.gamma = gamma
    self.candidates = candidates
    windowObserver.onChange = { [weak self] in self?.scheduleUpdate(because: "window") }
  }

  func start() {
    isRunning = true
    followFrontmostApp()

    if clickMonitor == nil {
      clickMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleUpdate(because: "click") }
      }
    }

    scheduleUpdate(because: "start")
  }

  func stop() {
    isRunning = false
    windowObserver.stop()
    if let clickMonitor {
      NSEvent.removeMonitor(clickMonitor)
    }
    clickMonitor = nil
    Task { [debouncer] in await debouncer.cancel() }
    lift()
  }

  /// Called from `AppModel`'s activation observer, which already delivers this
  /// event for the app rules and the permission refresh.
  func frontmostAppChanged() {
    guard isRunning else { return }
    followFrontmostApp()
    scheduleUpdate(because: "app")
  }

  /// Re-evaluates without waiting, for the moments where the answer is known to
  /// have changed for a reason other than focus: the setting was toggled, a
  /// display was plugged in, a panel opted out.
  func settingsChanged() {
    guard isRunning else { return }
    // Straight to the update. A settings change is a deliberate act by someone
    // watching the screen, and making them wait out a debounce meant for
    // ⌘-Tab would read as the switch being broken.
    lastReason = "settings"
    Task { await update() }
  }

  /// Where the pointer is, right now.
  ///
  /// A single query at the moment a focus event arrives, not a monitor on the
  /// mouse — the same one `AppModel` uses to aim the keys. Continuously
  /// following the pointer was turned down and still is; this reads it once,
  /// when something else has already woken us.
  private static var pointerDisplayID: CGDirectDisplayID? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(location) }?.displayID
  }

  private func followFrontmostApp() {
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    isWatchingWindows = windowObserver.follow(pid: pid)
  }

  private func scheduleUpdate(because reason: String) {
    lastReason = reason
    Task { [weak self, debouncer] in
      await debouncer.trigger { [weak self] in
        await self?.update()
      }
    }
  }

  private func update() async {
    let settings = preferences.global.attention
    let displays = candidates()

    // Nothing is asked of any other process while the feature is off or there
    // is only one screen. The read below is inter-process, and paying for it to
    // answer a question nobody switched on would be wrong.
    let isLive = settings.isEnabled && displays.count > 1

    // Off the main actor, with the relaxed budget. Waiting a quarter of a
    // second on the main actor would stall the interface; waiting here costs
    // nothing — and it buys an answer where the event tap's 50 ms would have
    // timed out and returned nil, which the plan cannot tell apart from "this
    // application has no window". That indistinguishability is the whole of
    // "sometimes it doesn't react": whether a browser answers in 50 ms depends
    // on what it happens to be doing.
    var focused: CGDirectDisplayID?
    if isLive, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
      let frame = await Task.detached(priority: .userInitiated) {
        FocusedWindowScreen.frame(
          forProcessIdentifier: pid, timeout: FocusedWindowScreen.relaxedTimeout
        )
      }.value
      focused = frame.flatMap { FocusedWindowScreen.displayID(containing: $0) }
    }
    // Only consulted when the window could not be found — clicking a desktop
    // makes the Finder frontmost with no focused window, and without this that
    // click lifts every veil and looks like the feature doing nothing.
    let pointer = isLive && focused == nil ? Self.pointerDisplayID : nil

    let veils = AttentionPlan.veils(
      for: displays, focused: focused, pointer: pointer, settings: settings
    )

    logger.info("""
      via=\(self.lastReason, privacy: .public) \
      enabled=\(settings.isEnabled, privacy: .public) \
      watchingWindows=\(self.isWatchingWindows, privacy: .public) \
      displays=[\(displays.map { "\($0.displayID)\($0.participates ? "" : "!optedOut")" }
        .joined(separator: " "), privacy: .public)] \
      frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
        privacy: .public) \
      focused=\(focused.map(String.init) ?? "none", privacy: .public) \
      pointer=\(pointer.map(String.init) ?? "-", privacy: .public) \
      veils=[\(veils.sorted { $0.key < $1.key }
        .map { "\($0.key):\(String(format: "%.2f", $0.value))" }
        .joined(separator: " "), privacy: .public)]
      """)

    for (displayID, veil) in veils {
      gamma.setVeil(veil, for: displayID)
    }
  }

  /// Takes every veil off, whatever the settings say.
  ///
  /// Used when the feature stops. Goes through the candidate list rather than
  /// `GammaDimmer.veiledDisplays` so a display that has just gone away is not
  /// resurrected, and so this cannot touch dimming, warmth or finish on the way
  /// past.
  private func lift() {
    for candidate in candidates() {
      gamma.setVeil(1.0, for: candidate.displayID)
    }
  }
}
