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
  private(set) var isReadingCapabilityString = false

  /// The parsed capability string, once read. This is what makes input
  /// switching possible at all.
  private(set) var capabilityString: CapabilityString?
  /// Raw value of VCP 0x60, believed only when it matches a declared input.
  private(set) var reportedInput: UInt8?

  private(set) var accent: Color

  /// Contrast has no strategy layer: it is DDC or it is nothing. Cached because
  /// panels do not all use 100 as the maximum.
  private var contrastMaximum: UInt16 = 100

  private let brightnessController: BrightnessController
  private let volumeController: VolumeController
  private let queue: DDCQueue?
  private let preferences: Preferences
  let log: DiagnosticsLog

  /// The concrete transport, kept for the capability string — that request does
  /// not fit the VCP-shaped `DDCTransport` protocol, and inventing a protocol
  /// method for one Apple Silicon specific call would be worse than this.
  private let arm64Transport: Arm64DDCTransport?

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
    self.log = log
    self.arm64Transport = display.transport as? Arm64DDCTransport

    let settings = preferences.settings(for: display.key)
    self.capabilities = settings.capabilities
    self.capabilityString = settings.capabilityString.map(CapabilityString.init(raw:))
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

  /// True only when the *display itself* answers DDC audio commands.
  ///
  /// The distinction matters for where the slider goes: a monitor's own
  /// speakers belong to that monitor, while the system output volume is global
  /// and lives at the panel's foot. Conflating them puts an identical-looking
  /// slider under every monitor that all move the same thing.
  var hasDisplayAudio: Bool { volumeRoute == .displaySpeakers }

  /// Any volume path at all, including the system output.
  var supportsVolume: Bool { volumeRoute != .unavailable }

  /// Why there is no volume slider.
  ///
  /// Worth spelling out rather than just omitting the control: "the app cannot
  /// do this" and "the app forgot to offer this" look identical from the
  /// outside, and the difference matters when the fix is to switch output
  /// device.
  var volumeUnavailableReason: String? {
    guard volumeRoute == .unavailable else { return nil }
    let device = SystemVolume.defaultOutputDeviceName() ?? "the current output device"
    if capabilities?.isUsable(.audioSpeakerVolume) == false, queue != nil {
      return "\(name) has no DDC audio control, and \(device) has a fixed digital "
        + "output whose level macOS cannot change. Switching audio output to the "
        + "built-in speakers or headphones gives you a slider here."
    }
    return "\(device) has no volume macOS can change."
  }

  /// Re-evaluates the audio route after the output device changed.
  func refreshVolumeRoute() async {
    let route = await volumeController.route
    // Re-prime even when the route name is unchanged: switching between two
    // devices that both support volume keeps the route but changes the value.
    await volumeController.reprime()

    volumeRoute = route
    volume = await volumeController.volume()
    isMuted = await volumeController.isMuted()
    log.record(.info("\(name): audio route is \(route.displayName)"))
  }

  var supportsContrast: Bool { capabilities?.isUsable(.contrast) == true }

  /// Whether the hardware brightness keys should act on this display.
  var respondsToMediaKeys: Bool { preferences.settings(for: key).respondsToMediaKeys }

  /// Inputs the display itself declared, in its capability string.
  ///
  /// Empty until the string has been read, and empty for panels that do not
  /// enumerate. Nothing is ever offered that is not in here: an input code that
  /// merely looks plausible switches the monitor to a dead signal, and because
  /// DDC travels over the video link, there is no way back except the monitor's
  /// own buttons.
  var availableInputs: [UInt8] {
    capabilityString?.values(for: .inputSource)?.sorted() ?? []
  }

  var availablePowerModes: [PowerMode] {
    (capabilityString?.values(for: .powerMode) ?? []).compactMap(PowerMode.init(rawValue:))
  }

  /// What the display claims is its current input — which may well be nonsense.
  ///
  /// The panel this was developed against reports 0x07 while declaring only
  /// 0x0F, 0x10, 0x11 and 0x12. So this is nil unless the reported value is one
  /// the display actually admits to having, and the UI says "unknown" rather
  /// than pointing at the wrong entry.
  var currentInput: UInt8? {
    guard let reported = reportedInput, availableInputs.contains(reported) else { return nil }
    return reported
  }

  /// True when the display reports an input it does not itself list.
  ///
  /// Worth calling out separately, because it is worse than not knowing. It
  /// means the connection currently in use has no entry to switch back to — a
  /// USB-C connection on a display that lists only DisplayPort and HDMI, for
  /// instance. Switching away is then irreversible from software in a stronger
  /// sense than usual: there is nothing to switch back *to*.
  var currentInputIsUnlisted: Bool {
    guard let reported = reportedInput, !availableInputs.isEmpty else { return false }
    return !availableInputs.contains(reported)
  }

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

  /// Same, but awaitable. Applying a preset uses this to finish with one display
  /// before starting the next, so their DDC traffic never overlaps.
  func commitBrightnessAndWait() async {
    await brightnessController.settle()
    await queue?.flush()
  }

  // MARK: - Inputs and power

  /// Reads the capability string, which is the only way to learn which input
  /// values the display accepts.
  ///
  /// On demand and cached: it costs a dozen or more round trips. The parsed
  /// result is stored under the `DisplayKey`, so a panel is asked once ever
  /// rather than once per launch.
  func readCapabilityString() async {
    guard let transport = arm64Transport, !isReadingCapabilityString else { return }
    isReadingCapabilityString = true
    defer { isReadingCapabilityString = false }

    let raw: String? = await Task.detached(priority: .utility) {
      try? transport.readCapabilities(timing: await self.settings.timing)
    }.value

    guard let raw, !raw.isEmpty else {
      log.record(.warning("\(name): no capability string; input switching stays unavailable"))
      return
    }

    capabilityString = CapabilityString(raw: raw)
    preferences.update(key) { $0.capabilityString = raw }

    if let queue, let reading = try? await queue.read(.inputSource) {
      reportedInput = UInt8(truncatingIfNeeded: reading.current)
    }
  }

  /// Switches the display to another input.
  ///
  /// One-way in practice: when the monitor leaves the Mac's input, the video
  /// link goes with it, and the DDC channel rides on that link. There is no
  /// software path back. The caller is responsible for having confirmed this
  /// with the user first.
  func switchInput(to value: UInt8) {
    guard availableInputs.contains(value), let queue else { return }
    log.record(.info("\(name): switching input to \(InputSource.name(for: value))"))
    Task { await queue.set(.inputSource, value: UInt16(value)) }
  }

  /// Puts the display into a low-power state. Waking it needs mouse movement or
  /// the monitor's own button.
  func setPowerMode(_ mode: PowerMode) {
    guard let queue else { return }
    log.record(.info("\(name): power mode → \(mode.displayName)"))
    Task { await queue.set(.powerMode, value: UInt16(mode.rawValue)) }
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
