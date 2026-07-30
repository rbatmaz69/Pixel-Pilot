import CoreGraphics
import PixelPilotCore
import SwiftUI

/// One display, as the UI sees it.
///
/// The controllers underneath are actors and everything they do is async. This
/// type is the main-actor face of that: it holds the values the views read
/// synchronously and forwards changes down. Views never await.
@MainActor
@Observable
final class DisplayViewModel: Identifiable {
  nonisolated var id: String { key.rawValue }

  let key: DisplayKey
  let displayID: CGDirectDisplayID
  let name: String
  let isBuiltin: Bool

  /// 0...1. Written by the UI, read back after a key press or an external
  /// change; never polled.
  var brightness: Double = 1.0
  var contrast: Double = 0.5
  var volume: Double = 0
  var isMuted: Bool = false

  private(set) var capabilities: DisplayCapabilities?
  private(set) var brightnessStrategy: BrightnessStrategy = .automatic
  private(set) var volumeRoute: VolumeController.Route = .unavailable
  private(set) var isReady = false
  /// True while a capability re-probe is running, so the UI can say so rather
  /// than appearing frozen for the several seconds it takes.
  private(set) var isProbing = false

  private(set) var accent: Color

  /// Contrast has no strategy layer: it is DDC or it is nothing. Cached because
  /// panels do not all use 100 as the maximum.
  private var contrastMaximum: UInt16 = 100

  private let brightnessController: BrightnessController
  private let volumeController: VolumeController
  private let queue: DDCQueue?
  private let preferences: Preferences

  init(
    display: DiscoveredDisplay,
    preferences: Preferences,
    log: DiagnosticsLog
  ) {
    self.key = display.key
    self.displayID = display.displayID
    self.name = display.name
    self.isBuiltin = display.isBuiltin
    self.preferences = preferences

    let settings = preferences.settings(for: display.key)
    self.capabilities = settings.capabilities
    self.accent = AccentPalette.color(for: display.key, override: settings.accentOverride)

    let queue = display.transport.map {
      DDCQueue(transport: $0, timing: settings.timing, log: log)
    }
    self.queue = queue
    self.brightnessController = BrightnessController(
      display: display, queue: queue, settings: settings, log: log
    )
    self.volumeController = VolumeController(
      queue: queue, capabilities: settings.capabilities, log: log
    )
  }

  /// One-time setup: probe capabilities if we have never seen this panel, then
  /// read its current state.
  ///
  /// The probe result is cached against the `DisplayKey`, so this costs six DDC
  /// round trips the first time a monitor is ever connected and nothing on every
  /// launch after that.
  func activate() async {
    var settings = preferences.settings(for: key)

    if settings.capabilities == nil, let queue {
      let probed = await queue.probeCapabilities()
      settings.capabilities = probed
      capabilities = probed
      preferences.update(key) {
        $0.capabilities = probed
        $0.lastKnownName = name
      }
      await brightnessController.updateSettings(settings)
    }

    await brightnessController.prime()
    await volumeController.prime()

    brightness = await brightnessController.brightness()
    brightnessStrategy = await brightnessController.effectiveStrategy
    volume = await volumeController.volume()
    isMuted = await volumeController.isMuted()
    volumeRoute = await volumeController.route

    await primeContrast()

    isReady = true
  }

  private func primeContrast() async {
    guard let queue, capabilities?.isUsable(.contrast) == true else { return }
    guard let reading = try? await queue.read(.contrast), reading.maximum > 0 else { return }
    contrastMaximum = reading.maximum
    contrast = Double(reading.current) / Double(reading.maximum)
  }

  /// Discards the cached capability probe and asks the panel again.
  ///
  /// Manual because it is expensive — one DDC round trip per feature, each with
  /// a 50 ms settling delay. Worth offering when a monitor's firmware has been
  /// updated or it was probed over a flaky cable, but never automatic.
  func reprobeCapabilities() async {
    guard let queue, !isProbing else { return }
    isProbing = true
    defer { isProbing = false }

    let probed = await queue.probeCapabilities()
    capabilities = probed
    preferences.update(key) { $0.capabilities = probed }

    var settings = preferences.settings(for: key)
    settings.capabilities = probed
    await brightnessController.updateSettings(settings)
    await primeContrast()
  }

  // MARK: - What the UI should offer

  /// True when brightness can be changed at all. Gamma dimming works on
  /// anything, so this is only false in genuinely broken states.
  var supportsBrightness: Bool { true }

  /// False when the panel's DDC audio is a stub *and* the system output has no
  /// settable volume — a DisplayPort-attached monitor with no speakers, for
  /// instance. Showing a slider there would be showing a control that does
  /// nothing.
  var supportsVolume: Bool { volumeRoute != .unavailable }

  var supportsContrast: Bool { capabilities?.isUsable(.contrast) == true }

  /// Whether the hardware brightness keys should act on this display.
  var respondsToMediaKeys: Bool { preferences.settings(for: key).respondsToMediaKeys }

  /// Explains the current path in one short phrase, for the panel footer.
  var routeDescription: String {
    var parts = [brightnessStrategy.displayName]
    if supportsVolume { parts.append(volumeRoute.displayName) }
    return parts.joined(separator: " · ")
  }

  // MARK: - Actions

  /// Continuous updates during a drag. Cheap: the DDC write is coalesced.
  func setBrightness(_ value: Double) {
    brightness = value
    Task { await brightnessController.setBrightness(value) }
  }

  /// End of a drag — let the queue drain so the final value is definitely out.
  func commitBrightness() {
    Task { await brightnessController.settle() }
  }

  func setContrast(_ value: Double) {
    contrast = value
    guard let queue else { return }
    Task { await queue.set(.contrast, value: UInt16((value * Double(contrastMaximum)).rounded())) }
  }

  // MARK: - Per-display settings

  /// Applies a settings change and re-derives whatever depends on it.
  ///
  /// Changing the brightness strategy is the interesting case: the new path has
  /// its own idea of the current value, so the display is re-read rather than
  /// assumed to be wherever the old path left it.
  func updateSettings(_ mutate: @escaping (inout DisplaySettings) -> Void) {
    let before = preferences.settings(for: key)
    preferences.update(key, mutate)
    let after = preferences.settings(for: key)

    accent = AccentPalette.color(for: key, override: after.accentOverride)

    Task {
      if after.timing != before.timing {
        await queue?.setTiming(after.timing)
      }
      await brightnessController.updateSettings(after)

      if after.brightnessStrategy != before.brightnessStrategy {
        // The gamma path and the DDC path can be at different levels; leaving
        // the old one applied would mean the slider no longer matches the screen.
        if before.usesGamma {
          GammaDimmer.shared.clear(displayID)
        }
        await brightnessController.reprime()
        brightness = await brightnessController.brightness()
      }
      brightnessStrategy = await brightnessController.effectiveStrategy
    }
  }

  var settings: DisplaySettings { preferences.settings(for: key) }

  /// Nudges brightness by a step and returns the new value *synchronously*.
  ///
  /// The caller needs the value right away to render the HUD in the same frame
  /// as the key press. Awaiting the actor first would put the indicator a frame
  /// behind the keyboard, which is exactly the lag people notice.
  @discardableResult
  func adjustBrightness(by step: Double) -> Double {
    let target = min(1, max(0, brightness + step))
    brightness = target
    Task { await brightnessController.setBrightness(target) }
    return target
  }

  @discardableResult
  func adjustVolume(by step: Double) -> Double {
    let target = min(1, max(0, volume + step))
    volume = target
    if target > 0 { isMuted = false }
    Task {
      await volumeController.setVolume(target)
      isMuted = await volumeController.isMuted()
    }
    return target
  }

  func setVolume(_ value: Double) {
    volume = value
    Task {
      await volumeController.setVolume(value)
      isMuted = await volumeController.isMuted()
    }
  }

  func toggleMute() {
    let target = !isMuted
    isMuted = target
    Task { await volumeController.setMuted(target) }
  }
}
