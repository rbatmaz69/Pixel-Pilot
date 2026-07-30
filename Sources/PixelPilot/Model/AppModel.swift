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

  let log = DiagnosticsLog()
  let preferences = Preferences.shared

  let hotkeys = HotkeyStore()

  @ObservationIgnored private let events = DisplayEvents()
  @ObservationIgnored private let osd = OSDController()
  @ObservationIgnored private let mediaKeys = MediaKeyTap()
  @ObservationIgnored private let hotkeyCenter = HotkeyCenter()
  @ObservationIgnored private var activationTask: Task<Void, Never>?

  func start() {
    events.onDisplaysChanged = { [weak self] in self?.refresh() }
    events.onWake = { [weak self] in
      // Gamma does not survive sleep, and a display may have changed while we
      // were out. Both need handling, in that order.
      GammaDimmer.shared.reassertAll()
      self?.refresh()
    }
    events.onColorSettingsChanged = {
      // Night Shift or a profile change just reset the gamma table.
      GammaDimmer.shared.reassertAll()
    }
    events.start()

    mediaKeys.handler = { [weak self] event in
      self?.handleMediaKey(event) ?? false
    }
    startMediaKeys()

    hotkeyCenter.handler = { [weak self] action in
      self?.handleHotkey(action)
    }
    hotkeyCenter.start()
    registerHotkeys()

    refresh()
  }

  func stop() {
    events.stop()
    mediaKeys.stop()
    hotkeyCenter.stop()
    osd.hide()
    activationTask?.cancel()
    // Leaving a display dimmed after quitting would be indistinguishable from
    // a broken monitor.
    GammaDimmer.shared.clearAll()
  }

  /// Rebuilds the display list.
  ///
  /// View models are recreated rather than diffed. That is the honest choice:
  /// a `CGDirectDisplayID` is reassigned across reconfigurations, so "the same
  /// display" can only be established via `DisplayKey`, and the per-display
  /// state that matters is persisted under that key anyway.
  func refresh() {
    let discovered = DisplayRegistry.discover(log: log)

    GammaDimmer.shared.pruneOffline(
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
      return false
    }
    mediaKeysActive = mediaKeys.start()
    return mediaKeysActive
  }

  var needsAccessibilityPermission: Bool {
    preferences.global.mediaKeysEnabled && !MediaKeyTap.isTrusted
  }

  func requestAccessibilityPermission() {
    MediaKeyTap.requestTrust()
    MediaKeyTap.openAccessibilitySettings()
  }

  /// Decides whether Pixel Pilot handles a media key, or lets macOS have it.
  ///
  /// The default is to decline. Consuming a key the app cannot act on leaves the
  /// user with a brightness key that does nothing for as long as the app runs —
  /// a far worse outcome than not handling it at all.
  private func handleMediaKey(_ event: MediaKeyTap.Event) -> Bool {
    guard let display = focusedDisplay, display.isReady else { return false }

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
      guard display.supportsVolume else { return false }
      let value = display.adjustVolume(by: event.key == .volumeUp ? step : -step)
      present(display.isMuted ? .muted : .volume, value: value, on: display)
      return true

    case .mute:
      guard display.supportsVolume else { return false }
      display.toggleMute()
      present(display.isMuted ? .muted : .volume, value: display.volume, on: display)
      return true
    }
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
    guard let display = focusedDisplay, display.isReady else { return }
    let step = preferences.global.keyStep

    switch action {
    case .brightnessUp, .brightnessDown:
      let value = display.adjustBrightness(by: action == .brightnessUp ? step : -step)
      present(.brightness, value: value, on: display)

    case .volumeUp, .volumeDown:
      guard display.supportsVolume else { return }
      let value = display.adjustVolume(by: action == .volumeUp ? step : -step)
      present(display.isMuted ? .muted : .volume, value: value, on: display)

    case .toggleMute:
      guard display.supportsVolume else { return }
      display.toggleMute()
      present(display.isMuted ? .muted : .volume, value: display.volume, on: display)
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
