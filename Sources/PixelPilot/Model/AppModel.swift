import AppKit
import PixelPilotCore
import SwiftUI

/// Top-level state.
///
/// Owns display discovery and keeps the view models in step with what is
/// actually plugged in. Everything here is event-driven — see `DisplayEvents`.
@MainActor
@Observable
final class AppModel {
  private(set) var displays: [DisplayViewModel] = []
  private(set) var isDDCAvailable = Arm64DDCTransport.isSupported

  /// Whether the media keys are actually being intercepted. Surfaced so the UI
  /// can explain the missing permission instead of silently doing nothing.
  private(set) var mediaKeysActive = false
  /// Whether the HID layer is being watched as well, which is what makes
  /// third-party keyboards' brightness keys work.
  private(set) var hidKeysActive = false

  /// The most recent consumer-page press seen, whether or not it was
  /// recognised — the settings window shows it so an unsupported keyboard can
  /// be identified rather than guessed at.
  private(set) var lastObservedKey: (usage: UInt32, device: String)?

  /// Cached permission state. Observable, unlike the system calls behind it,
  /// so the UI stops warning once a grant actually happens.
  private(set) var accessibilityGranted = false
  private(set) var inputMonitoringGranted = false

  /// Keyboards the HID listener is attached to. Empty means nothing was
  /// matched, which is a different problem from a keyboard that sends nothing.
  private(set) var watchedKeyboards: [String] = []

  /// The taught keys, mirrored out of the store.
  ///
  /// The store itself is not observable and cannot be: it lives in the UI-free
  /// package, where importing Observation to satisfy SwiftUI would be exactly
  /// the dependency that package exists to avoid. Nor would `@Observable` help
  /// if it were imported — a `let` property is not instrumented by the macro,
  /// so a view reading `model.keyBindings.bindings` establishes no dependency
  /// at all and never redraws when a key is taught or forgotten.
  ///
  /// So the store stays private and every mutation goes through this type,
  /// which republishes the result. Views read the mirror.
  private(set) var keyBindingList: [KeyBindingStore.Binding] = []

  /// The press captured while the learning sheet is open, awaiting confirmation.
  private(set) var pendingLearnedPress: HIDMediaKeyMonitor.RawPress?
  var isLearningKey: Bool { hidKeys.isLearning }

  let log = DiagnosticsLog()
  let preferences: Preferences

  let hotkeys = HotkeyStore()
  let systemAudio = SystemAudioModel()

  /// The presets, mirrored out of the store — see `keyBindingList` for why the
  /// store cannot be read directly from a view.
  private(set) var presetList: [Preset] = []
  /// Which preset follows which system appearance, mirrored for the same reason.
  private(set) var appearanceBindings = PresetStore.AppearanceBindings()

  /// Where displays come from. Injectable so reconnect and disappearance can be
  /// tested without unplugging a cable.
  @ObservationIgnored private let discovery: any DisplayDiscovering
  @ObservationIgnored private let gamma: GammaDimmer
  @ObservationIgnored private let presets: PresetStore
  @ObservationIgnored private let keyBindings: KeyBindingStore
  @ObservationIgnored private let appRules: AppRuleStore

  init(
    discovery: any DisplayDiscovering = SystemDisplayDiscovery(),
    gamma: GammaDimmer = .shared,
    preferences: Preferences = .shared,
    presets: PresetStore = .shared,
    keyBindings: KeyBindingStore = .shared,
    appRules: AppRuleStore = .shared
  ) {
    self.discovery = discovery
    self.gamma = gamma
    self.preferences = preferences
    self.presets = presets
    self.keyBindings = keyBindings
    self.appRules = appRules
    syncPresets()
    syncKeyBindings()
    syncAppRules()
  }

  /// Republishes the preset store. Called after every mutation, and once at
  /// init — a mirror that is only refreshed on change starts out empty.
  private func syncPresets() {
    presetList = presets.presets
    appearanceBindings = presets.appearanceBindings
  }

  private func syncKeyBindings() {
    keyBindingList = keyBindings.bindings
  }

  @ObservationIgnored private var presetTask: Task<Void, Never>?
  @ObservationIgnored private var audioObservation: SystemVolume.DefaultOutputObservation?
  @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

  @ObservationIgnored private let events = DisplayEvents()
  @ObservationIgnored private let osd = OSDController()
  @ObservationIgnored private let mediaKeys = MediaKeyTap()
  @ObservationIgnored private let hidKeys = HIDMediaKeyMonitor()
  /// One press can reach us through both paths; whichever arrives first wins.
  @ObservationIgnored private var keyDeduplicator = MediaKeyDeduplicator()
  @ObservationIgnored private let hotkeyCenter = HotkeyCenter()
  @ObservationIgnored private var activationTask: Task<Void, Never>?

  func start() {
    events.onDisplaysChanged = { [weak self] in self?.refresh() }
    events.onWake = { [weak self] in
      // Gamma does not survive sleep, and a display may have changed while we
      // were out. Both need handling, in that order.
      self?.gamma.reassertAll()
      self?.refresh()
      // Silently: the built-in panel may be somewhere else than when we went to
      // sleep, and that is a new baseline rather than an ambient change to
      // chase down the I2C bus in the first second after a wake.
      self?.builtinSource.resync()
    }
    events.onColorSettingsChanged = { [weak self] in
      // Night Shift or a profile change just reset the gamma table.
      self?.gamma.reassertAll()
      // And it may keep doing it. Displays carrying a white point of ours count
      // the resets so the colour card can say what is happening, rather than
      // the app silently fighting something it cannot see.
      self?.displays.forEach { $0.noteColorSettingsChanged() }
    }
    events.onAccessibilityTrustChanged = { [weak self] in
      self?.refreshPermissions()
    }
    events.onAppearanceChanged = { [weak self] isDark in
      // The theme follows the system only when it has been asked to, but the
      // store needs the fact either way — this is the app's one observer of it.
      ThemeStore.shared.systemIsDark = isDark
      self?.applyAppearancePreset(isDark: isDark)
    }
    events.start()

    mediaKeys.handler = { [weak self] event in
      self?.handleMediaKey(event) ?? false
    }
    hidKeys.handler = { [weak self] event in
      self?.handleHIDKey(event)
    }
    hidKeys.observer = { [weak self] press in
      guard let self else { return }
      lastObservedKey = (press.signature.usage, press.deviceName)
      // The learning sheet is watching this.
      if hidKeys.isLearning {
        // The one moment in the learning sheet worth acknowledging: the key
        // that was pressed has been caught. The sheet says so visually; this
        // says so without having to look at the screen, which is the position
        // someone reaching for an unlabelled key is usually in.
        if pendingLearnedPress?.signature != press.signature { Haptics.confirm() }
        pendingLearnedPress = press
      } else if let action = keyBindings.action(for: press.signature) {
        // A taught key beats the built-in mapping, so a wrong guess on our part
        // can be corrected.
        applyLearned(action, on: press)
      }
    }
    hidKeys.learnedSignatures = keyBindings.watchedSignatures()
    startMediaKeys()

    hotkeyCenter.handler = { [weak self] action in
      self?.handleHotkey(action)
    }
    hotkeyCenter.start()
    registerHotkeys()

    // Whether volume is controllable at all depends on the current output
    // device, so it has to be re-evaluated when that changes rather than only
    // at launch.
    audioObservation = SystemVolume.observeDefaultOutputDevice { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.systemAudio.refresh()
        for display in self.displays {
          await display.refreshVolumeRoute()
        }
      }
    }
    systemAudio.refresh()

    // Coming back from System Settings is the moment a grant becomes real, and
    // it is an event rather than something to poll for.
    // One observer, two jobs. A second registration for the app rules would be
    // a second thing to remember to tear down, for an event that is already
    // being delivered here.
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] notification in
      // Read out of the notification here, in the delivering context, and only
      // the string is carried across — `NSRunningApplication` is not `Sendable`
      // and the identifier is all this needs.
      let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication)?.bundleIdentifier
      MainActor.assumeIsolated {
        self?.refreshPermissions()
        self?.frontmostAppChanged(to: identifier)
        // Three jobs on this observer now. The attention controller needs the
        // same event for a different reason: to re-point its window observer at
        // whichever application is now in front.
        self?.attention.frontmostAppChanged()
      }
    }
    refreshPermissions()

    refresh()

    scheduleRunner.start()
    refreshSchedule()
    attention.start()
  }

  func stop() {
    // Both before the gamma teardown below, so what they put on comes off
    // through the thing that put it there rather than being left for
    // `clearAll` — which for a suspended display would mean quitting with our
    // tables held back and nothing to resume them.
    testPatterns.hide()
    attention.stop()
    scheduleRunner.stop()
    builtinSource.stop()
    events.stop()
    mediaKeys.stop()
    hotkeyCenter.stop()
    hidKeys.stop()
    audioObservation = nil
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    activationObserver = nil
    osd.hide()
    activationTask?.cancel()
    // Leaving a display dimmed after quitting would be indistinguishable from
    // a broken monitor.
    gamma.clearAll()
  }

  /// Rebuilds the display list.
  ///
  /// View models are recreated rather than diffed. That is the honest choice:
  /// a `CGDirectDisplayID` is reassigned across reconfigurations, so "the same
  /// display" can only be established via `DisplayKey`, and the per-display
  /// state that matters is persisted under that key anyway.
  func refresh() {
    screenLayoutTick += 1
    let discovered = discovery.discoverDisplays(log: log)

    gamma.pruneOffline(
      onlineDisplayIDs: Set(discovered.map(\.displayID))
    )

    displays = discovered.map {
      DisplayViewModel(display: $0, preferences: preferences, log: log)
    }
    for display in displays {
      display.sourceBrightness = { [weak self] in self?.builtinSource.current }
    }
    refreshFollowing()
    // The set of displays is exactly what the veils are a function of, so a
    // monitor arriving or leaving has to be re-answered. `pruneOffline` above
    // drops what went; this puts the right thing on what is left.
    attention.settingsChanged()

    activationTask?.cancel()
    activationTask = Task { [displays] in
      // Sequential on purpose: these all talk to the same I2C bus, and
      // overlapping probes on a multi-monitor setup corrupt each other.
      for display in displays {
        guard !Task.isCancelled else { return }
        await display.activate()
      }
    }
  }

  // MARK: - Media keys

  /// Whether the app can stop macOS acting on a key, as opposed to merely
  /// seeing it.
  ///
  /// This replaces `hasKeyDrivableDisplay`, which asked whether an external
  /// display was plugged in and refused to watch the keys at all otherwise.
  /// That was the right question while the built-in panel was left to macOS and
  /// the two never aimed at the same thing. Now that the keys are taken over
  /// completely they do aim at the same thing — the same backlight, the same
  /// system output — and the only thing separating "the app changes it" from
  /// "the app and macOS both change it, two steps per press" is the event tap,
  /// because the HID monitor can watch a key but never swallow it.
  ///
  /// So anything macOS would have done itself is declined while this is false,
  /// and macOS is left to do it alone. An external panel's own backlight and
  /// its own speakers stay fair game either way: macOS does not know they
  /// exist.
  var canTakeOverFromSystem: Bool { mediaKeysActive }

  @discardableResult
  func startMediaKeys() -> Bool {
    guard preferences.global.mediaKeysEnabled else {
      mediaKeysActive = false
      hidKeysActive = false
      mediaKeys.stop()
      hidKeys.stop()
      return false
    }
    mediaKeysActive = mediaKeys.start()
    // Independent of the tap: a keyboard whose keys macOS never translates is
    // exactly the case where the tap succeeds and still sees nothing. Costs
    // measurable CPU while open, hence the separate switch.
    if preferences.global.hidMediaKeysEnabled {
      hidKeysActive = hidKeys.start()
    } else {
      hidKeys.stop()
      hidKeysActive = false
    }
    watchedKeyboards = hidKeys.attachedDevices
    keyDeduplicator.reset()
    return mediaKeysActive || hidKeysActive
  }

  /// Re-reads both permissions and restarts whatever can now run.
  ///
  /// Has to be called rather than computed. Both checks are function calls into
  /// the system, not observable state, so SwiftUI has no way to notice that a
  /// grant happened — an earlier version left the warning on screen after the
  /// user had already switched the app on, which is worse than no warning.
  func refreshPermissions() {
    let accessibility = MediaKeyTap.isTrusted
    let inputMonitoring = HIDMediaKeyMonitor.isTrusted

    let changed = accessibility != accessibilityGranted
      || inputMonitoring != inputMonitoringGranted
    accessibilityGranted = accessibility
    inputMonitoringGranted = inputMonitoring

    // A grant that arrives while running is useless until the listeners are
    // started, and they were refused the last time they tried.
    if changed {
      startMediaKeys()
    }
  }

  var needsAccessibilityPermission: Bool {
    preferences.global.mediaKeysEnabled && !accessibilityGranted
  }

  /// Input Monitoring is a separate grant from Accessibility, and it is the one
  /// that makes brightness keys work on keyboards other than Apple's.
  var needsInputMonitoringPermission: Bool {
    preferences.global.mediaKeysEnabled && !inputMonitoringGranted
  }

  func requestAccessibilityPermission() {
    MediaKeyTap.requestTrust()
    MediaKeyTap.openAccessibilitySettings()
  }

  func requestInputMonitoringPermission() {
    HIDMediaKeyMonitor.requestTrust()
    HIDMediaKeyMonitor.openInputMonitoringSettings()
  }

  /// True when a permission has been granted but the listener it unlocks is
  /// still not running.
  ///
  /// macOS decides HID access at the moment the connection is opened, and a
  /// process that was refused stays refused for its lifetime — so granting
  /// Input Monitoring to a running app changes nothing until it restarts.
  /// Without saying this, the app looks broken precisely when the user has just
  /// done everything right.
  var needsRelaunchForPermissions: Bool {
    guard preferences.global.mediaKeysEnabled else { return false }
    return (inputMonitoringGranted && !hidKeysActive)
      || (accessibilityGranted && !mediaKeysActive)
  }

  /// Relaunches the app.
  ///
  /// Spawns a detached copy that waits for this process to exit before opening
  /// the bundle — launching straight away would collide with the copy that is
  /// still running.
  func relaunch() {
    let bundleURL = Bundle.main.bundleURL
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; "
        + "open \"\(bundleURL.path)\"",
    ]
    try? process.run()

    stop()
    NSApplication.shared.terminate(nil)
  }

  // MARK: - Teaching keys

  func beginLearningKey() {
    pendingLearnedPress = nil
    hidKeys.beginLearning()
  }

  func cancelLearningKey() {
    pendingLearnedPress = nil
    hidKeys.endLearning()
  }

  /// Confirms the captured press as the key for `action`.
  func confirmLearnedKey(as action: MediaKeyAction) {
    guard let press = pendingLearnedPress else { return }
    keyBindings.bind(press.signature, to: action, keyboardName: press.deviceName)

    pendingLearnedPress = nil
    hidKeys.endLearning()
    // The monitor narrows its matching to the taught keys, so it has to be told
    // about the new one or the key it just learned would not be watched.
    hidKeys.learnedSignatures = keyBindings.watchedSignatures()
    hidKeys.refreshMatching()
    syncKeyBindings()

    log.record(.info("Learned \(press.signature.description) as \(action.displayName)"))
  }

  func forgetLearnedKey(_ signature: KeySignature) {
    keyBindings.unbind(signature)
    hidKeys.learnedSignatures = keyBindings.watchedSignatures()
    hidKeys.refreshMatching()
    syncKeyBindings()
  }

  /// Runs a taught binding.
  private func applyLearned(_ action: MediaKeyAction, on press: HIDMediaKeyMonitor.RawPress) {
    let key: MediaKeyTap.Key = switch action {
    case .brightnessUp: .brightnessUp
    case .brightnessDown: .brightnessDown
    case .volumeUp: .volumeUp
    case .volumeDown: .volumeDown
    case .mute: .mute
    }
    // No deduplication here: `handleMediaKey` is the single place that decides,
    // and checking in both would consume the slot and then discard against it.
    _ = handleMediaKey(MediaKeyTap.Event(key: key, isRepeat: false, isFineAdjustment: false))
  }

  /// Handles a key seen at the HID layer.
  ///
  /// Same actions as the event tap, minus the pass-through decision: reading
  /// HID does not consume the event, so macOS still gets its copy. That is why
  /// keys the app cannot act on need no special handling here.
  private func handleHIDKey(_ event: HIDMediaKeyMonitor.Event) {
    let action: MediaKeyTap.Key = switch event.key {
    case .brightnessUp: .brightnessUp
    case .brightnessDown: .brightnessDown
    case .volumeUp: .volumeUp
    case .volumeDown: .volumeDown
    case .mute: .mute
    }

    // Deduplication happens once, inside `handleMediaKey`. Checking here as
    // well would take the slot and then fail against it.
    _ = handleMediaKey(
      MediaKeyTap.Event(key: action, isRepeat: false, isFineAdjustment: false)
    )
  }

  /// Decides whether Pixel Pilot handles a media key, or lets macOS have it.
  ///
  /// The default is to decline. Consuming a key the app cannot act on leaves the
  /// user with a brightness key that does nothing for as long as the app runs —
  /// a far worse outcome than not handling it at all.
  private func handleMediaKey(_ event: MediaKeyTap.Event) -> Bool {
    guard let display = focusedDisplay, display.isReady else { return false }

    // The same physical press arrives over both paths, so the second copy must
    // not act again — and must answer exactly as the first one did. Replying
    // "consumed" here regardless is what broke the brightness keys once: the
    // HID copy arrives first, the app declines it — the display it was pointed
    // at is still being probed, say, or its own key switch is off — and then
    // the tap copy swallows a key nobody acted on.
    if let decided = keyDeduplicator.previousDecision(for: event.key.deduplicationKey) {
      return decided
    }

    let consumed = decideMediaKey(event, on: display)
    keyDeduplicator.record(consumed, for: event.key.deduplicationKey)
    return consumed
  }

  private func decideMediaKey(_ event: MediaKeyTap.Event, on display: DisplayViewModel) -> Bool {
    let settings = preferences.global
    let step = event.isFineAdjustment ? settings.fineKeyStep : settings.keyStep

    switch event.key {
    case .brightnessUp, .brightnessDown:
      guard MediaKeyPolicy.handlesBrightness(
        isBuiltin: display.isBuiltin,
        respondsToMediaKeys: display.respondsToMediaKeys,
        strategy: display.brightnessStrategy,
        canTakeOverFromSystem: canTakeOverFromSystem
      ) else { return false }
      stepBrightness(by: event.key == .brightnessUp ? step : -step, on: display)
      return true

    case .volumeUp, .volumeDown:
      // The display's own speakers win when it has them; otherwise the system
      // output, which is what the keys would have reached anyway.
      if display.hasDisplayAudio {
        let value = display.adjustVolume(by: event.key == .volumeUp ? step : -step)
        presentDisplayVolume(value, on: display)
        return true
      }
      guard MediaKeyPolicy.handlesSystemVolume(
        isControllable: systemAudio.isControllable,
        canTakeOverFromSystem: canTakeOverFromSystem
      ) else { return sayThereIsNoVolume(on: display) }
      let value = systemAudio.adjustVolume(by: event.key == .volumeUp ? step : -step)
      presentSystemVolume(value, on: display)
      return true

    case .mute:
      if display.hasDisplayAudio {
        display.toggleMute()
        presentDisplayVolume(display.volume, on: display)
        return true
      }
      guard MediaKeyPolicy.handlesSystemVolume(
        isControllable: systemAudio.isControllable,
        canTakeOverFromSystem: canTakeOverFromSystem
      ) else { return sayThereIsNoVolume(on: display) }
      systemAudio.toggleMute()
      presentSystemVolume(systemAudio.volume, on: display)
      return true
    }
  }

  /// One brightness step, on one screen or on all of them.
  ///
  /// Which it is comes from `KeyTarget.movesEveryDisplay`, so the keys and the
  /// global shortcuts cannot drift apart on it — and both go through the same
  /// group the panel's master slider drives, rather than a second copy of the
  /// same arithmetic. Arming that group on the first press is not a side
  /// effect: the master row appearing in the panel *is* the setting, shown.
  ///
  /// With one display there is no group to move, so it falls through to the
  /// ordinary path rather than pretending.
  private func stepBrightness(by step: Double, on display: DisplayViewModel) {
    guard preferences.global.keyTarget.movesEveryDisplay, canSyncBrightness else {
      presentBrightness(display.adjustBrightness(by: step), on: display)
      return
    }
    stepEveryDisplayBrightness(by: step, drawnOn: display)
  }

  /// The group, moved by a step, whatever the key target says.
  ///
  /// Split out because two shortcuts mean it unconditionally — "normally one
  /// screen, but this key does all of them".
  private func stepEveryDisplayBrightness(by step: Double, drawnOn display: DisplayViewModel) {
    if !isSyncingBrightness { setSyncingBrightness(true) }
    setMasterBrightness(min(1, max(0, masterBrightness + step)))
    commitMasterBrightness()
    presentMasterBrightness(masterBrightness, on: display)
  }

  /// Answers a volume key that has nowhere to go.
  ///
  /// The alternative — and what this did until now — was to pass the press
  /// through and let it vanish. From the outside "the app is not running", "the
  /// app ignores this key" and "the app tried and this monitor has no volume
  /// control" are the same silence, and only the last one is true. On a monitor
  /// with no DDC audio and a digital output at a fixed level, that silence is
  /// every volume key press, all day.
  ///
  /// **Only when the press can also be swallowed.** Without that, macOS acts on
  /// the same key and draws its own indicator, and the answer to a silent HUD
  /// would be two of them. `canTakeOverFromSystem` is already false in every
  /// case where `handlesSystemVolume` was false for the other reason, so this
  /// reads as: we could have taken the key, there was simply nothing to do with
  /// it.
  private func sayThereIsNoVolume(on display: DisplayViewModel) -> Bool {
    guard canTakeOverFromSystem else { return false }
    presentNoVolume(on: display)
    return true
  }

  /// The indicator itself, for the callers that have already decided to show it.
  private func presentNoVolume(on display: DisplayViewModel) {
    present(
      .unavailable(.volume),
      value: 0,
      on: display,
      detail: display.volumeUnavailableSummary,
      adjust: nil,
      commit: nil
    )
  }

  // MARK: - App rules

  /// The rules, mirrored out of the store — see `keyBindingList` for why.
  private(set) var appRuleList: [AppRule] = []
  var fallbackPresetID: UUID? { appRules.fallbackPresetID }

  /// The last bundle identifier a rule was applied for.
  ///
  /// Guards against re-applying on every activation of the same app. Coming
  /// back from a Finder window or a dialog is an activation too, and putting a
  /// round of DDC writes behind each of those would make the whole machine feel
  /// slow for no visible reason.
  @ObservationIgnored private var lastRuleTarget: String?

  /// Rounds up bursts of app switching. ⌘-Tab held down sends one of these per
  /// app passed through, and each would otherwise be a preset pushed down the
  /// I2C bus.
  @ObservationIgnored private let ruleDebouncer = Debouncer(delay: .milliseconds(200))

  // MARK: - Attention

  /// Pushes back the screens not being worked on. Off unless switched on, so
  /// this is inert on a fresh installation.
  ///
  /// The candidate list is a closure rather than a snapshot because displays
  /// come and go, and a stale one would leave a veil on a monitor that is no
  /// longer there — or miss one that has just arrived.
  @ObservationIgnored private lazy var attention = AttentionController(
    preferences: preferences
  ) { [weak self] in
    (self?.displays ?? []).map {
      AttentionPlan.Candidate(displayID: $0.displayID, participates: $0.settings.dimsWhenUnfocused)
    }
  }

  /// Re-evaluates the veils after something other than focus changed the
  /// answer: the switch itself, the amount, or a display opting out.
  func attentionSettingsChanged() {
    attention.settingsChanged()
  }

  // MARK: - Test patterns

  @ObservationIgnored private let testPatterns = TestPatternController()

  func showTestPatterns(on display: DisplayViewModel) {
    testPatterns.show(on: display.displayID, named: display.name)
  }

  func saveAppRule(_ rule: AppRule) {
    appRules.save(rule)
    syncAppRules()
  }

  func deleteAppRule(id: UUID) {
    appRules.delete(id: id)
    syncAppRules()
  }

  func setFallbackPreset(_ id: UUID?) {
    appRules.fallbackPresetID = id
    syncAppRules()
  }

  private func syncAppRules() {
    appRuleList = appRules.rules
  }

  private func frontmostAppChanged(to bundleIdentifier: String?) {
    guard !appRuleList.isEmpty || fallbackPresetID != nil else { return }

    // Which preset the new frontmost app calls for — its own rule, or the
    // fallback. Deciding this before the debounce keeps the comparison against
    // `lastRuleTarget` honest when several apps flash past.
    let target = bundleIdentifier.flatMap { appRules.rule(forBundleIdentifier: $0)?.presetID }
      ?? fallbackPresetID
    guard let target else { return }

    let identity = "\(target)"
    guard identity != lastRuleTarget else { return }

    Task { [weak self] in
      await self?.ruleDebouncer.trigger {
        await MainActor.run {
          guard let self, let preset = self.presets.preset(id: target) else { return }
          self.lastRuleTarget = identity
          self.log.record(.info("Applying '\(preset.name)' for the frontmost app"))
          self.apply(preset)
        }
      }
    }
  }

  // MARK: - Schedule

  @ObservationIgnored private lazy var scheduleRunner = ScheduleRunner { [weak self] stop in
    self?.applyScheduleStop(stop)
  }

  /// When the next scheduled change is due, for the settings UI.
  var nextScheduledChange: Date? { scheduleRunner.nextFire }

  func updateSchedule(_ mutate: (inout DaySchedule) -> Void) {
    preferences.updateGlobal { mutate(&$0.schedule) }
    refreshSchedule()
  }

  func setCoordinate(latitude: Double?, longitude: Double?) {
    preferences.updateGlobal {
      // Rounded here rather than at the point of asking, so a coordinate
      // arriving from anywhere is reduced the same way.
      $0.latitude = latitude.map { ($0 * 10).rounded() / 10 }
      $0.longitude = longitude.map { ($0 * 10).rounded() / 10 }
    }
    refreshSchedule()
  }

  private func refreshSchedule() {
    let global = preferences.global
    let coordinate: (latitude: Double, longitude: Double)? =
      if let latitude = global.latitude, let longitude = global.longitude {
        (latitude, longitude)
      } else {
        nil
      }
    scheduleRunner.update(schedule: global.schedule, coordinate: coordinate)
  }

  /// One stop, applied to every display.
  ///
  /// Absolute values, not a nudge: a schedule that adjusted relative to
  /// whatever the displays happened to be at would drift a little further
  /// every day and end up somewhere nobody chose.
  private func applyScheduleStop(_ stop: ScheduleStop) {
    switch stop.action {
    case let .values(brightness, kelvin):
      applyScheduledValues(brightness: brightness, kelvin: kelvin)

    case let .preset(id):
      // A stop pointing at a preset that has since been deleted does nothing,
      // and says so in the log rather than looking like the schedule failed to
      // fire. The stop is left alone: the settings row marks it, and removing
      // somebody's hand-placed stop on their behalf is not this code's call.
      guard let preset = presets.preset(id: id) else {
        log.record(.info("Scheduled preset is missing — nothing applied"))
        return
      }
      groupChangeTick += 1
      log.record(.info("Applying scheduled preset '\(preset.name)'"))
      // Not `apply(_:)`: that one confirms with a haptic, which belongs to a
      // press. A tap at the wrist at ten in the evening, with nobody touching
      // anything, is the app claiming credit for a decision made hours ago.
      run(preset)
    }
  }

  private func applyScheduledValues(brightness: Double?, kelvin: Double?) {
    groupChangeTick += 1
    log.record(.info("Applying scheduled change"))

    presetTask?.cancel()
    presetTask = Task { [displays] in
      for display in displays {
        guard !Task.isCancelled else { return }
        if let brightness {
          display.setBrightness(brightness)
        }
        if let kelvin {
          // 6500 K is neutral, and neutral means no table of ours at all
          // rather than a very slight tint.
          display.setColorTemperature(
            abs(kelvin - ColorTemperature.neutralKelvin) < 1 ? nil : kelvin
          )
        }
        await display.commitBrightnessAndWait()
      }
    }
  }

  // MARK: - Following the built-in panel

  /// The one watcher of the built-in panel, shared by every display that
  /// follows it.
  ///
  /// Not `private`, because the settings card reports which of the two ways it
  /// is getting its values — those cost different amounts and the app says so.
  @ObservationIgnored lazy var builtinSource = BuiltinBrightnessSource { [weak self] value in
    self?.applyFollowedBrightness(source: value)
  }

  /// The panel macOS is adjusting to the room. Absent on a Mac with no display
  /// of its own, and on a laptop whose lid is shut.
  var builtinDisplay: DisplayViewModel? { displays.first(where: \.isBuiltin) }

  var followingDisplays: [DisplayViewModel] {
    displays.filter { !$0.isBuiltin && $0.followsBuiltinBrightness }
  }

  /// Starts or stops the watcher to match what is actually plugged in and what
  /// has actually been asked for.
  ///
  /// Called after every display reconfiguration and after the toggle, both of
  /// which fire more often than the answer changes — hence `start(watching:)`
  /// being idempotent rather than this being careful.
  func refreshFollowing() {
    guard !followingDisplays.isEmpty, let builtin = builtinDisplay else {
      builtinSource.stop()
      return
    }
    builtinSource.start(watching: builtin.displayID)
  }

  /// Switches following on or off for one display, and makes it visible at once.
  ///
  /// Applying immediately matters more here than it looks: the next ambient
  /// change might be an hour away, and a switch that appears to do nothing for
  /// an hour is a switch nobody trusts again.
  func setFollowsBuiltinBrightness(_ isOn: Bool, for display: DisplayViewModel) {
    display.setFollowsBuiltinBrightness(isOn)
    refreshFollowing()
    guard isOn, let source = builtinSource.current else { return }
    applyFollowedBrightness(source: source)
  }

  /// Records the current pair as the relationship to keep, for the "Match now"
  /// button — the same lesson a manual adjustment teaches, asked for outright.
  func matchFollowNow(_ display: DisplayViewModel) {
    guard let source = builtinSource.current else { return }
    display.updateSettings {
      $0.followCurve.learn(source: source, target: display.brightness)
    }
    Haptics.confirm()
  }

  /// Moves every following display to where its curve says it belongs.
  ///
  /// No `groupChangeTick` and no OSD, unlike every other bulk change in this
  /// type. Those exist to say "you did that, and it landed"; this one nobody
  /// did. A HUD that flashed every time the light in the room shifted would be
  /// the single most irritating thing this app could do.
  private func applyFollowedBrightness(source: Double) {
    // The master slider is the transient, hand-driven mode, and while it is on
    // it owns every display's brightness. Two things writing the same value
    // would just be a fight nobody can see the sides of.
    guard !isSyncingBrightness else { return }

    let followers = followingDisplays
    guard !followers.isEmpty else { return }

    // Deliberately the same task slot as presets, the schedule and the master.
    // These all write brightness to several displays over one I2C bus, and the
    // only coherent rule when two of them overlap is that the later one wins —
    // which is also what makes "a preset holds until the room next changes"
    // true rather than aspirational.
    presetTask?.cancel()
    presetTask = Task { [followers] in
      for display in followers {
        guard !Task.isCancelled else { return }
        display.applyFollowedBrightness(forSource: source)
        await display.commitBrightnessAndWait()
      }
    }
  }

  // MARK: - Remembered displays

  /// Every panel ever seen, newest information first, for the settings UI.
  ///
  /// Republished like the preset list, and for the same reason: `Preferences`
  /// is in the UI-free package and cannot be observable.
  private(set) var knownDisplays: [(key: DisplayKey, settings: DisplaySettings)] = []

  func refreshKnownDisplays() {
    knownDisplays = preferences.knownDisplays()
      .sorted { $0.value.lastKnownName.localizedStandardCompare($1.value.lastKnownName) == .orderedAscending }
      .map { (key: $0.key, settings: $0.value) }
  }

  func isConnected(_ key: DisplayKey) -> Bool {
    displays.contains { $0.key == key }
  }

  /// Throws away everything remembered about a panel.
  ///
  /// If it happens to be plugged in, it is re-probed immediately rather than
  /// left in a half state — a connected display with no capability cache would
  /// otherwise show every control as unavailable until the next reconnect.
  func forgetDisplay(_ key: DisplayKey) {
    preferences.forget(key)
    if let display = displays.first(where: { $0.key == key }) {
      Task { await display.reprobeCapabilities() }
    }
    refreshKnownDisplays()
  }

  // MARK: - Identifying

  @ObservationIgnored private let identify = IdentifyController()

  /// Bumped when the screens are added, removed or rearranged, so the display
  /// map recomputes its geometry then and at no other time.
  private(set) var screenLayoutTick = 0

  /// Puts a number on every screen for a couple of seconds.
  ///
  /// The numbers match the sidebar order rather than anything the system
  /// assigns, because the sidebar is what the question is being asked about.
  func identifyDisplays() {
    Haptics.confirm()
    var labels: [CGDirectDisplayID: (number: Int, name: String, accent: Color)] = [:]
    for (index, display) in displays.enumerated() {
      labels[display.displayID] = (index + 1, display.name, display.accent)
    }
    identify.show(labels: labels)
  }

  // MARK: - Moving every display at once

  /// Whether the brightness sliders are ganged together.
  private(set) var isSyncingBrightness = false
  /// Where the master sits. Only meaningful while syncing.
  private(set) var masterBrightness: Double = 1

  /// Captured when the group is armed, and never re-derived.
  ///
  /// Re-deriving from what the displays are currently at would destroy the
  /// spread the moment one of them clamps at an end — see `BrightnessSync`,
  /// where the arithmetic and the test for that live.
  @ObservationIgnored private var syncOffsets: [DisplayKey: Double] = [:]

  /// Bumped whenever several displays change together, to run the accent wave.
  private(set) var groupChangeTick = 0

  /// The preset most recently applied, whoever applied it.
  ///
  /// Only "next preset" and "previous preset" read it. It is not a claim that
  /// the displays are still in that state — a slider moved afterwards makes it
  /// stale immediately — only a note of where stepping should carry on from.
  private(set) var lastAppliedPresetID: UUID?

  /// Opens or closes the menu bar panel.
  ///
  /// A closure because the panel belongs to `StatusItemController` and this
  /// object has no business knowing what one is — the same arrangement
  /// `MenuBarPanel` uses to reach the settings window. Set in `install()`.
  var onTogglePanel: (() -> Void)?

  /// Only worth offering when there is more than one thing to gang.
  var canSyncBrightness: Bool { displays.count > 1 }

  func setSyncingBrightness(_ isOn: Bool) {
    isSyncingBrightness = isOn
    guard isOn else {
      syncOffsets = [:]
      return
    }
    let levels = Dictionary(uniqueKeysWithValues: displays.map { ($0.key, $0.brightness) })
    masterBrightness = BrightnessSync.suggestedMaster(levels: levels)
    syncOffsets = BrightnessSync.offsets(levels: levels, master: masterBrightness)
  }

  /// Moves every display, keeping their differences.
  ///
  /// Called continuously while the master is dragged, so it must stay cheap:
  /// `setBrightness` goes through `DDCQueue`, which coalesces. The expensive
  /// verified write happens once, in `commitMasterBrightness`.
  func setMasterBrightness(_ value: Double) {
    masterBrightness = value
    let levels = BrightnessSync.levels(master: value, offsets: syncOffsets)
    for display in displays {
      guard let level = levels[display.key] else { continue }
      display.setBrightness(level)
    }
  }

  func commitMasterBrightness() {
    groupChangeTick += 1
    presetTask?.cancel()
    presetTask = Task { [displays] in
      // Sequential, for the same reason applying a preset is: these share an
      // I2C bus, and overlapping transactions on it corrupt each other rather
      // than queueing.
      for display in displays {
        guard !Task.isCancelled else { return }
        await display.commitBrightnessAndWait()
      }
    }
  }

  // MARK: - Presets

  /// Applies a preset, one display at a time.
  ///
  /// Sequential for the same reason display activation is: the displays share an
  /// I2C bus, and overlapping transactions on it corrupt each other rather than
  /// queueing.
  func apply(_ preset: Preset) {
    // Before the fan-out, not after it. Writing brightness to every display
    // takes hundreds of milliseconds of DDC round trips, and an
    // acknowledgement that arrives at the end of that has stopped being an
    // acknowledgement of the click.
    Haptics.confirm()
    groupChangeTick += 1
    run(preset)
  }

  /// The preset itself, with nothing said about it.
  ///
  /// Split out from `apply(_:)` so the schedule can apply a preset without the
  /// haptic and without a second copy of the fan-out. The confirmation and the
  /// wave belong to the press; the writes belong to the preset.
  private func run(_ preset: Preset) {
    // Recorded here rather than in `apply(_:)`, so a preset that arrived from
    // the schedule, an app rule or the system appearance also becomes the place
    // "next preset" steps on from. Carrying on from wherever the displays
    // actually are is the only reading of "next" that is not a surprise.
    lastAppliedPresetID = preset.id
    presetTask?.cancel()
    presetTask = Task { [displays] in
      for display in displays {
        guard !Task.isCancelled else { return }
        guard let entry = preset.entry(for: display.key) else { continue }

        if let brightness = entry.brightness {
          display.setBrightness(brightness)
        }
        if let contrast = entry.contrast, display.supportsContrast {
          display.setContrast(contrast)
        }
        if let volume = entry.volume, display.supportsVolume {
          display.setVolume(volume)
        }
        // Colour goes through the gamma table rather than the bus, so it costs
        // no round trip and needs no place in the sequencing below. `nil` here
        // is `PresetColor.neutral`, which takes our white point off the display
        // altogether — that is what makes a "Day" preset able to undo a "Night"
        // one rather than only being able to warm things differently.
        if let color = entry.color {
          display.setColorTemperature(color.kelvinValue)
        }
        // The finish rides in the same table on the same terms, so the note
        // above covers it: no round trip, no place in the sequencing, and
        // `.off` genuinely takes the curve off rather than flattening it.
        if let finish = entry.finish {
          display.setToneCurve(finish.curveValue)
        }
        await display.commitBrightnessAndWait()
      }
      log.record(.info("Applied preset '\(preset.name)'"))
    }
  }

  /// What every connected display is set to right now.
  ///
  /// One source for both capturing and re-capturing. They had no business
  /// drifting apart — a preset made today and the same preset refreshed
  /// tomorrow have to mean the same thing.
  func currentEntries() -> [DisplayKey: PresetEntry] {
    var entries: [DisplayKey: PresetEntry] = [:]
    for display in displays {
      entries[display.key] = PresetEntry(
        brightness: display.brightness,
        contrast: display.supportsContrast ? display.contrast : nil,
        volume: display.supportsVolume ? display.volume : nil,
        color: PresetColor(kelvinValue: display.colorTemperatureKelvin),
        finish: PresetFinish(curveValue: display.toneCurve)
      )
    }
    return entries
  }

  /// Captures what every display is set to right now.
  func captureCurrentState(name: String, symbolName: String) -> Preset {
    let preset = Preset(name: name, symbolName: symbolName, entries: currentEntries())
    presets.save(preset)
    syncPresets()
    return preset
  }

  /// Refreshes an existing preset from the current state, in place.
  ///
  /// The alternative people were left with was delete-and-recapture, which
  /// changes the preset's identity — and takes its hotkey, its app rules and
  /// its appearance binding with it. Everything about the preset except the
  /// numbers survives this.
  func recapture(_ preset: Preset) -> Preset {
    let updated = preset.updating(entries: currentEntries())
    presets.save(updated)
    syncPresets()
    Haptics.confirm()
    log.record(.info("Re-captured preset '\(updated.name)'"))
    return updated
  }

  /// Saves an edited preset — name and symbol, which are the two things about a
  /// preset that cannot be captured by setting the displays up.
  func updatePreset(_ preset: Preset) {
    presets.save(preset)
    syncPresets()
  }

  func deletePreset(id: UUID) {
    presets.delete(id: id)
    // Otherwise "next preset" would step on from a preset that no longer has a
    // place in the list, and land somewhere arbitrary.
    if lastAppliedPresetID == id { lastAppliedPresetID = nil }
    let existing = Set(presets.presets.map(\.id))
    hotkeys.pruneMissingPresets(existing: existing)
    // A rule aimed at a deleted preset is the worst kind of broken: still
    // listed, still looks right, and never fires.
    appRules.pruneMissingPresets(existing: existing)
    syncAppRules()
    registerHotkeys()
    // After `pruneMissingPresets`, because deleting a preset can clear an
    // appearance binding that pointed at it, and the mirror has to show that.
    syncPresets()
  }

  func movePresets(fromOffsets source: IndexSet, toOffset destination: Int) {
    presets.move(fromOffsets: source, toOffset: destination)
    syncPresets()
  }

  func updateAppearanceBindings(_ mutate: (inout PresetStore.AppearanceBindings) -> Void) {
    presets.updateAppearanceBindings(mutate)
    syncPresets()
  }

  /// Applies whichever preset is bound to the current appearance.
  private func applyAppearancePreset(isDark: Bool) {
    guard let preset = presets.preset(forDarkAppearance: isDark) else { return }
    log.record(.info("Appearance switched to \(isDark ? "dark" : "light")"))
    apply(preset)
  }

  // MARK: - Global shortcuts

  func setHotkey(_ shortcut: Shortcut?, for action: HotkeyCenter.Action) {
    hotkeys.set(shortcut, for: action)
    registerHotkeys()
  }

  private func registerHotkeys() {
    hotkeyCenter.unregisterAll()
    for (action, shortcut) in hotkeys.shortcuts {
      hotkeyCenter.register(shortcut, for: action)
    }
  }

  /// Unlike the media keys, a shortcut the user assigned deliberately is always
  /// acted on. There is no "pass it through" case — they chose it for this.
  private func handleHotkey(_ action: HotkeyCenter.Action) {
    switch action {
    case let .preset(id):
      guard let preset = presets.preset(id: id) else { return }
      apply(preset)

    case let .builtin(builtin):
      // Neither of these needs a display, and demanding one would make them
      // stop working in exactly the situation they are most useful in — nothing
      // answering on the bus, and no way to find the panel.
      switch builtin {
      case .openPanel:
        onTogglePanel?()
        return
      case .identifyDisplays:
        identifyDisplays()
        return
      case .nextPreset, .previousPreset:
        stepPreset(forward: builtin == .nextPreset)
        return
      default:
        break
      }

      guard let display = focusedDisplay, display.isReady else { return }
      // Always the coarse step. A shortcut cannot carry the Shift-and-Option
      // that gets `fineKeyStep` out of a media key, because those modifiers are
      // already part of the shortcut itself.
      let step = preferences.global.keyStep

      switch builtin {
      case .brightnessUp, .brightnessDown:
        stepBrightness(by: builtin == .brightnessUp ? step : -step, on: display)

      case .allBrightnessUp, .allBrightnessDown:
        guard canSyncBrightness else {
          // One display is the whole group. Doing the ordinary thing beats
          // doing nothing and beats claiming a group that is not there.
          presentBrightness(
            display.adjustBrightness(by: builtin == .allBrightnessUp ? step : -step),
            on: display
          )
          return
        }
        stepEveryDisplayBrightness(
          by: builtin == .allBrightnessUp ? step : -step, drawnOn: display
        )

      case .contrastUp, .contrastDown:
        guard display.supportsContrast else { return presentNoContrast(on: display) }
        presentContrast(
          display.adjustContrast(by: builtin == .contrastUp ? step : -step), on: display
        )

      case .warmer, .cooler:
        // The step is a fraction of the Kelvin range rather than of 0…1, so one
        // press means the same share of the scale here as it does anywhere else.
        let range = ColorTemperature.range
        let span = (range.upperBound - range.lowerBound) * step
        presentWarmth(
          display.adjustColorTemperature(by: builtin == .warmer ? -span : span), on: display
        )

      case .volumeUp, .volumeDown:
        if display.hasDisplayAudio {
          let value = display.adjustVolume(by: builtin == .volumeUp ? step : -step)
          presentDisplayVolume(value, on: display)
        } else if systemAudio.isControllable {
          let value = systemAudio.adjustVolume(by: builtin == .volumeUp ? step : -step)
          presentSystemVolume(value, on: display)
        } else {
          // A shortcut the user chose themselves, so there is no macOS press to
          // collide with and nothing to check before answering.
          presentNoVolume(on: display)
        }

      case .toggleMute:
        if display.hasDisplayAudio {
          display.toggleMute()
          presentDisplayVolume(display.volume, on: display)
        } else if systemAudio.isControllable {
          systemAudio.toggleMute()
          presentSystemVolume(systemAudio.volume, on: display)
        } else {
          presentNoVolume(on: display)
        }

      case .openPanel, .identifyDisplays, .nextPreset, .previousPreset:
        // Answered above, before a display was required.
        break
      }
    }
  }

  /// Steps through the presets in the order they are listed.
  ///
  /// From nothing, the first — someone who has never applied one and presses
  /// "next" means "give me one", not "give me the second". Wraps at both ends,
  /// because a list you can walk off is a shortcut that stops working and does
  /// not say why.
  /// Not private, so `HotkeyTests` can drive it. Registering a real Carbon
  /// shortcut and pressing it is the only other way in, and neither of those is
  /// something a test can do.
  func stepPreset(forward: Bool) {
    guard !presetList.isEmpty else { return }
    let index = lastAppliedPresetID.flatMap { id in
      presetList.firstIndex { $0.id == id }
    }
    let next: Int = if let index {
      (index + (forward ? 1 : -1) + presetList.count) % presetList.count
    } else {
      forward ? 0 : presetList.count - 1
    }
    let preset = presetList[next]
    apply(preset)
    if let display = focusedDisplay {
      presentPreset(preset, on: display)
    }
  }

  /// - Parameters:
  ///   - adjust: What dragging the indicator's track means, or nil for one with
  ///     nothing to drag. Built here rather than resolved by `OSDController`,
  ///     because which thing a HUD is about is knowledge this object already
  ///     has and that one has stayed free of: the same volume indicator is a
  ///     display's speakers on one machine and the system output on the next.
  ///
  ///     **No default value, deliberately.** It had one, and the media keys —
  ///     the path that puts this HUD on screen more than every other caller put
  ///     together — quietly took it and shipped an indicator with no handle on
  ///     it. Every test passed, because each one supplied the closure the app
  ///     did not. A parameter with no default is the compiler asking the
  ///     question at each call site, which is the only place that can answer it.
  ///   - name: What the HUD calls what it is about, when that is not one
  ///     display's name — the whole group, or a preset. `display` is then only
  ///     where to draw it and what colour to draw it in.
  private func present(
    _ kind: OSDKind,
    value: Double,
    on display: DisplayViewModel,
    name: String? = nil,
    detail: String? = nil,
    adjust: ((Double) -> Void)?,
    commit: (() -> Void)?
  ) {
    guard preferences.global.showsOSD else { return }
    osd.show(
      kind: kind,
      value: value,
      accent: display.accent,
      displayName: name ?? display.name,
      on: display.displayID,
      detail: detail,
      adjust: adjust,
      commit: commit
    )
  }

  /// The indicator for a display's brightness, draggable.
  ///
  /// Weakly captured: the closures outlive this call by as long as the HUD is
  /// up, and a display unplugged in the meantime should be let go rather than
  /// held alive by an indicator about it.
  private func presentBrightness(_ value: Double, on display: DisplayViewModel) {
    present(
      .brightness,
      value: value,
      on: display,
      adjust: { [weak display] in display?.setBrightness($0) },
      commit: { [weak display] in display?.commitBrightness() }
    )
  }

  /// A display's own speakers. No commit: `setVolume` writes straight through,
  /// with no verified second step for a drag to save up for.
  private func presentDisplayVolume(_ value: Double, on display: DisplayViewModel) {
    present(
      display.isMuted ? .muted : .volume,
      value: value,
      on: display,
      // A muted indicator says what happened; it is not a place to set a level.
      adjust: display.isMuted ? nil : { [weak display] in display?.setVolume($0) },
      commit: nil
    )
  }

  /// The system output. `display` is only where to draw it and what colour.
  private func presentSystemVolume(_ value: Double, on display: DisplayViewModel) {
    present(
      systemAudio.isMuted ? .muted : .volume,
      value: value,
      on: display,
      adjust: systemAudio.isMuted ? nil : { [weak self] in self?.systemAudio.setVolume($0) },
      commit: nil
    )
  }

  /// The scroll wheel over the menu bar icon, which wants exactly what a
  /// brightness key press wants: the on-screen indicator.
  func presentScrolledBrightness(_ value: Double, on display: DisplayViewModel) {
    presentBrightness(value, on: display)
  }

  /// The whole group, drawn on one screen and named for all of them.
  ///
  /// `display` is only the placement and the colour — the same arrangement
  /// `presentSystemVolume` uses for a value that is not the display's either.
  /// Dragging it moves the master, so the HUD is the master slider wherever the
  /// pointer already is.
  private func presentMasterBrightness(_ value: Double, on display: DisplayViewModel) {
    present(
      .brightness,
      value: value,
      on: display,
      name: Self.everyDisplayName,
      adjust: { [weak self] in self?.setMasterBrightness($0) },
      commit: { [weak self] in self?.commitMasterBrightness() }
    )
  }

  private func presentContrast(_ value: Double, on display: DisplayViewModel) {
    present(
      .contrast,
      value: value,
      on: display,
      adjust: { [weak display] in display?.setContrast($0) },
      commit: nil
    )
  }

  /// A panel with no contrast gets told so, for the reason
  /// `sayThereIsNoVolume` exists: silence cannot distinguish "did nothing"
  /// from "there is nothing here to do".
  private func presentNoContrast(on display: DisplayViewModel) {
    present(
      .unavailable(.contrast),
      value: 0,
      on: display,
      detail: "This display did not report a usable contrast control.",
      adjust: nil,
      commit: nil
    )
  }

  /// The white point, as a fraction of the Kelvin range so the track means the
  /// same thing it does on the colour card.
  private func presentWarmth(_ kelvin: Double?, on display: DisplayViewModel) {
    present(
      .warmth,
      value: KelvinTrack.fraction(of: kelvin ?? ColorTemperature.neutralKelvin),
      on: display,
      adjust: { [weak display] fraction in
        let range = ColorTemperature.range
        let target = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        display?.setColorTemperature(
          abs(target - ColorTemperature.neutralKelvin) < 1 ? nil : target
        )
      },
      commit: nil
    )
  }

  /// Says which preset just landed.
  ///
  /// No level and nothing to drag: it reports a thing that has already
  /// happened. Stepping through presets without it means pressing twice and
  /// then going to look at what you got.
  private func presentPreset(_ preset: Preset, on display: DisplayViewModel) {
    present(
      .preset(name: preset.name, symbol: preset.symbolName),
      value: 0,
      on: display,
      name: "Preset",
      adjust: nil,
      commit: nil
    )
  }

  /// What the HUD and the panel's master row both call the group. One constant,
  /// because two spellings of it is how they end up disagreeing.
  static let everyDisplayName = "All displays"

  // MARK: - Which screen a key press means

  /// The last answer from Accessibility, and when it was given.
  ///
  /// Asking is an inter-process round trip and this is read from inside the
  /// event tap, so it must not happen once per key repeat — a held brightness
  /// key fires roughly every 30 ms and would otherwise spend thirty round trips
  /// a second establishing something that has not changed. Deliberate presses
  /// are far enough apart to ask again, which is what keeps the answer current
  /// when the focus moves between two windows of the same application: there is
  /// no notification for that, so a value cached until the next app switch
  /// would go quietly stale.
  ///
  /// The same reasoning, and very nearly the same number, as
  /// `DisplayViewModel.brightnessResyncQuietPeriod`.
  @ObservationIgnored private var cachedFocusedWindowDisplay: (id: CGDirectDisplayID?, at: ContinuousClock.Instant)?
  private static let focusedWindowQuietPeriod: Duration = .milliseconds(400)

  private var focusedWindowDisplayID: CGDirectDisplayID? {
    if let cached = cachedFocusedWindowDisplay,
       ContinuousClock.now - cached.at < Self.focusedWindowQuietPeriod {
      return cached.id
    }
    let resolved = FocusedWindowScreen.current()
    cachedFocusedWindowDisplay = (resolved, .now)
    return resolved
  }

  private var pointerDisplayID: CGDirectDisplayID? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.displayID
  }

  /// The display a key press or the menu bar should act on.
  ///
  /// Used to be the pointer and nothing else, which on a laptop with a monitor
  /// plugged in is regularly the wrong screen: the pointer sits wherever it was
  /// last put down, and that is very often not where the window being typed in
  /// is. Since the app took over the built-in panel's keys as well, being wrong
  /// there means dimming a screen nobody was looking at.
  ///
  /// The rule itself is in `KeyTargetPolicy`, with the fallbacks written out and
  /// tested.
  var focusedDisplay: DisplayViewModel? {
    let target = KeyTargetPolicy.target(
      mode: preferences.global.keyTarget,
      focusedWindow: focusedWindowDisplayID,
      pointer: pointerDisplayID,
      connected: displays.map(\.displayID),
      isBuiltin: { id in displays.first { $0.displayID == id }?.isBuiltin ?? false }
    )
    return displays.first { $0.displayID == target }
  }
}

extension NSScreen {
  /// The `CGDirectDisplayID` behind this screen, which AppKit only exposes
  /// through the device description dictionary.
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
