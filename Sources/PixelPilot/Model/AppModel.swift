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

  init(
    discovery: any DisplayDiscovering = SystemDisplayDiscovery(),
    gamma: GammaDimmer = .shared,
    preferences: Preferences = .shared,
    presets: PresetStore = .shared,
    keyBindings: KeyBindingStore = .shared
  ) {
    self.discovery = discovery
    self.gamma = gamma
    self.preferences = preferences
    self.presets = presets
    self.keyBindings = keyBindings
    syncPresets()
    syncKeyBindings()
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
    }
    events.onColorSettingsChanged = { [weak self] in
      // Night Shift or a profile change just reset the gamma table.
      self?.gamma.reassertAll()
    }
    events.onAppearanceChanged = { [weak self] isDark in
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
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshPermissions() }
    }
    refreshPermissions()

    refresh()
  }

  func stop() {
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
    let discovered = discovery.discoverDisplays(log: log)

    gamma.pruneOffline(
      onlineDisplayIDs: Set(discovered.map(\.displayID))
    )

    displays = discovered.map {
      DisplayViewModel(display: $0, preferences: preferences, log: log)
    }

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
    // Also guards the tap path, so a press that arrived over HID a moment ago
    // is not acted on twice.
    guard keyDeduplicator.shouldHandle(key: event.key.deduplicationKey) else { return true }

    let settings = preferences.global
    let step = event.isFineAdjustment ? settings.fineKeyStep : settings.keyStep

    switch event.key {
    case .brightnessUp, .brightnessDown:
      // The built-in panel already does the right thing natively, including the
      // ambient-light behaviour we cannot reproduce. Leave it alone.
      guard !display.isBuiltin, display.respondsToMediaKeys else { return false }
      let value = display.adjustBrightness(by: event.key == .brightnessUp ? step : -step)
      present(.brightness, value: value, on: display)
      return true

    case .volumeUp, .volumeDown:
      // The display's own speakers win when it has them; otherwise the system
      // output, which is what the keys would have reached anyway.
      if display.hasDisplayAudio {
        let value = display.adjustVolume(by: event.key == .volumeUp ? step : -step)
        present(display.isMuted ? .muted : .volume, value: value, on: display)
        return true
      }
      guard systemAudio.isControllable else { return false }
      let value = systemAudio.adjustVolume(by: event.key == .volumeUp ? step : -step)
      present(systemAudio.isMuted ? .muted : .volume, value: value, on: display)
      return true

    case .mute:
      if display.hasDisplayAudio {
        display.toggleMute()
        present(display.isMuted ? .muted : .volume, value: display.volume, on: display)
        return true
      }
      guard systemAudio.isControllable else { return false }
      systemAudio.toggleMute()
      present(systemAudio.isMuted ? .muted : .volume, value: systemAudio.volume, on: display)
      return true
    }
  }

  // MARK: - Presets

  /// Applies a preset, one display at a time.
  ///
  /// Sequential for the same reason display activation is: the displays share an
  /// I2C bus, and overlapping transactions on it corrupt each other rather than
  /// queueing.
  func apply(_ preset: Preset) {
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
        // Input switching is deliberately not applied from presets. It is the
        // one action that can leave the Mac with no picture, and a preset is
        // exactly the wrong place for something that needs a confirmation.
        await display.commitBrightnessAndWait()
      }
      log.record(.info("Applied preset '\(preset.name)'"))
    }
  }

  /// Captures what every display is set to right now.
  func captureCurrentState(name: String, symbolName: String) -> Preset {
    var entries: [DisplayKey: PresetEntry] = [:]
    for display in displays {
      entries[display.key] = PresetEntry(
        brightness: display.brightness,
        contrast: display.supportsContrast ? display.contrast : nil
      )
    }
    let preset = Preset(name: name, symbolName: symbolName, entries: entries)
    presets.save(preset)
    syncPresets()
    return preset
  }

  func deletePreset(id: UUID) {
    presets.delete(id: id)
    hotkeys.pruneMissingPresets(existing: Set(presets.presets.map(\.id)))
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
      guard let display = focusedDisplay, display.isReady else { return }
      let step = preferences.global.keyStep

      switch builtin {
      case .brightnessUp, .brightnessDown:
        let value = display.adjustBrightness(by: builtin == .brightnessUp ? step : -step)
        present(.brightness, value: value, on: display)

      case .volumeUp, .volumeDown:
        if display.hasDisplayAudio {
          let value = display.adjustVolume(by: builtin == .volumeUp ? step : -step)
          present(display.isMuted ? .muted : .volume, value: value, on: display)
        } else if systemAudio.isControllable {
          let value = systemAudio.adjustVolume(by: builtin == .volumeUp ? step : -step)
          present(systemAudio.isMuted ? .muted : .volume, value: value, on: display)
        }

      case .toggleMute:
        if display.hasDisplayAudio {
          display.toggleMute()
          present(display.isMuted ? .muted : .volume, value: display.volume, on: display)
        } else if systemAudio.isControllable {
          systemAudio.toggleMute()
          present(systemAudio.isMuted ? .muted : .volume, value: systemAudio.volume, on: display)
        }
      }
    }
  }

  private func present(_ kind: OSDKind, value: Double, on display: DisplayViewModel) {
    guard preferences.global.showsOSD else { return }
    osd.show(
      kind: kind,
      value: value,
      accent: display.accent,
      displayName: display.name,
      on: display.displayID
    )
  }

  /// The display the menu bar or a key press should act on: whichever one holds
  /// the mouse, falling back to the main display.
  var focusedDisplay: DisplayViewModel? {
    let mouseLocation = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
       let displayID = screen.displayID,
       let match = displays.first(where: { $0.displayID == displayID }) {
      return match
    }
    return displays.first(where: { !$0.isBuiltin }) ?? displays.first
  }
}

extension NSScreen {
  /// The `CGDirectDisplayID` behind this screen, which AppKit only exposes
  /// through the device description dictionary.
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
