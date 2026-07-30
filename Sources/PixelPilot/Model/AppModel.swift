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

  let log = DiagnosticsLog()
  let preferences: Preferences

  let hotkeys = HotkeyStore()
  let presets = PresetStore.shared
  let systemAudio = SystemAudioModel()

  /// Where displays come from. Injectable so reconnect and disappearance can be
  /// tested without unplugging a cable.
  @ObservationIgnored private let discovery: any DisplayDiscovering
  @ObservationIgnored private let gamma: GammaDimmer

  init(
    discovery: any DisplayDiscovering = SystemDisplayDiscovery(),
    gamma: GammaDimmer = .shared,
    preferences: Preferences = .shared
  ) {
    self.discovery = discovery
    self.gamma = gamma
    self.preferences = preferences
  }

  @ObservationIgnored private var presetTask: Task<Void, Never>?
  @ObservationIgnored private var audioObservation: SystemVolume.DefaultOutputObservation?

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
    hidKeys.observer = { [weak self] usage, device in
      self?.lastObservedKey = (usage, device)
    }
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

    refresh()
  }

  func stop() {
    events.stop()
    mediaKeys.stop()
    hotkeyCenter.stop()
    audioObservation = nil
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
    // exactly the case where the tap succeeds and still sees nothing.
    hidKeysActive = hidKeys.start()
    keyDeduplicator.reset()
    return mediaKeysActive || hidKeysActive
  }

  var needsAccessibilityPermission: Bool {
    preferences.global.mediaKeysEnabled && !MediaKeyTap.isTrusted
  }

  /// Input Monitoring is a separate grant from Accessibility, and it is the one
  /// that makes brightness keys work on keyboards other than Apple's.
  var needsInputMonitoringPermission: Bool {
    preferences.global.mediaKeysEnabled && !HIDMediaKeyMonitor.isTrusted
  }

  func requestAccessibilityPermission() {
    MediaKeyTap.requestTrust()
    MediaKeyTap.openAccessibilitySettings()
  }

  func requestInputMonitoringPermission() {
    HIDMediaKeyMonitor.requestTrust()
    HIDMediaKeyMonitor.openInputMonitoringSettings()
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

    guard keyDeduplicator.shouldHandle(key: action.deduplicationKey) else { return }
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
    return preset
  }

  func deletePreset(id: UUID) {
    presets.delete(id: id)
    hotkeys.pruneMissingPresets(existing: Set(presets.presets.map(\.id)))
    registerHotkeys()
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
