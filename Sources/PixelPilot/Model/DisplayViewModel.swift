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

  /// Marks and the last health check, mirrored out of `Preferences`.
  ///
  /// Mirrored rather than read through `settings` because that property is a
  /// computed read of a store which is not `@Observable` — a view reading
  /// `settings.pixelDefects` establishes no dependency and never redraws when a
  /// mark is placed. Every other card on the settings page gets away with it by
  /// accident: `updateSettings` reassigns `accent` on every call and the whole
  /// page reads `accent`. That is not a mechanism to hang a card on, least of
  /// all one whose whole job is to reflect something changing on another
  /// screen.
  private(set) var pixelDefects: [PixelDefect]
  private(set) var healthReport: HealthReport?

  /// Contrast has no strategy layer: it is DDC or it is nothing. Cached because
  /// panels do not all use 100 as the maximum.
  private var contrastMaximum: UInt16 = 100

  /// When this app last moved brightness, so `resyncNativeBrightness` never
  /// reads back a value its own previous write has not landed on yet. Not
  /// observed: nothing in the UI depends on when a write happened.
  @ObservationIgnored private var lastBrightnessWrite: ContinuousClock.Instant?

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
    self.colorTemperatureKelvin = settings.colorTemperatureKelvin
    self.toneCurve = settings.toneCurve
    self.colorCapabilities = settings.colorCapabilities
    self.pixelDefects = settings.pixelDefects
    self.healthReport = settings.healthReport

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

    // A white point chosen on a previous launch has to be put back: the gamma
    // table does not survive a reboot, and a slider showing 3000 K over a
    // display that is actually neutral is worse than not remembering at all.
    // The finish is in the same table and has the same problem.
    applyWhitePoint()
    applyToneCurve()

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

  /// The same in one line, for the on-screen indicator.
  ///
  /// Next to the long form rather than built where it is shown, so the two
  /// cannot drift into disagreeing about which of them is true. A HUD is 210
  /// points wide and on screen for a second: the window gets the three
  /// sentences with the fix in them, this gets the fact.
  var volumeUnavailableSummary: String? {
    guard volumeRoute == .unavailable else { return nil }
    let device = SystemVolume.defaultOutputDeviceName() ?? "the output device"
    if capabilities?.isUsable(.audioSpeakerVolume) == false, queue != nil {
      return "\(name) has no DDC audio, and \(device) has a fixed level."
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

  // MARK: - Why a control is not doing what it looks like it should

  /// Whether there is a DDC channel to this display at all.
  ///
  /// `queue` stays private. This is the one bit of it any view needs, and it is
  /// a fact about the display rather than a handle on the bus.
  var hasDDCChannel: Bool { queue != nil }

  /// Why the brightness slider is disabled or behaving unusually, if it is.
  ///
  /// `!isReady` is the only thing that disables the slider, so this is also the
  /// sentence that explains a greyed-out control — which the panel had no way
  /// of saying at all before.
  var brightnessBlock: ControlBlock? {
    ControlAvailability.brightness(
      isReady: isReady,
      isProbing: isProbing,
      hasDDCChannel: hasDDCChannel,
      isBuiltin: isBuiltin,
      strategy: brightnessStrategy
    )
  }

  var contrastBlock: ControlBlock? {
    ControlAvailability.contrast(capabilities: capabilities)
  }

  /// Note the wording difference from `volumeUnavailableReason` above, which is
  /// deliberate and stays: that one names the current output device, which only
  /// the app can ask about, and is the right answer when there is room for it.
  /// This is the same fact with no room.
  var volumeBlock: ControlBlock? {
    ControlAvailability.volume(route: volumeRoute)
  }

  // MARK: - The display in one glance

  /// The worst thing currently true about this display.
  ///
  /// Read by the overview board, which shows every display at once and cannot
  /// give each one four lines. An ordering rather than a count, because three
  /// notes and one fault is a fault.
  ///
  /// Every input here is a stored property on this observable class, so this
  /// tracks. `settings` is deliberately *not* consulted: it reads `Preferences`,
  /// which is not observable, and a board built on it would go stale in place.
  var statusLevel: StatusLevel {
    var level = brightnessBlock?.level ?? .ok
    if healthReport?.overall == .faults { level = max(level, .warn) }
    if isFightingSomethingOverColor { level = max(level, .warn) }
    if currentInputIsUnlisted { level = max(level, .warn) }
    return level
  }

  /// This display in one line, for a board that shows several.
  ///
  /// The route first, because it is what differs between two monitors that
  /// otherwise look the same; then the health verdict; then at most one thing
  /// that is wrong. Capped at three clauses on purpose — a board whose rows
  /// wrap has become a list of paragraphs, and the display's own page is one
  /// click away and has the full sentences.
  ///
  /// `routeDescription` is reused rather than re-derived: the sidebar already
  /// shows it under the display's name, and the two must not disagree.
  ///
  /// Worth knowing about `currentInputIsUnlisted`, which feeds `statusLevel`
  /// above: it depends on `capabilityString`, which is only read on demand from
  /// the Input and power card. On a display whose page has never been opened it
  /// is nil and the answer is false. That is correct rather than a bug — do not
  /// "fix" it by probing from the overview, which would be a dozen DDC round
  /// trips per display every time the window opens.
  var statusHeadline: String {
    var parts = [routeDescription]
    parts.append(healthReport?.overall.displayName ?? "Never checked")
    if let block = brightnessBlock { parts.append(block.short) }
    return parts.joined(separator: " · ")
  }

  // MARK: - Actions

  /// Continuous updates during a drag. Cheap: the DDC write is coalesced.
  func setBrightness(_ value: Double) {
    brightness = value
    lastBrightnessWrite = .now
    Task { await brightnessController.setBrightness(value) }
  }

  /// End of a drag — let the queue drain so the final value is definitely out.
  ///
  /// Also the end of a deliberate adjustment, which is why the lesson is taken
  /// here rather than in `setBrightness`: the values passing through a drag are
  /// on the way to somewhere, and only the one it stops at was chosen.
  func commitBrightness() {
    scheduleFollowLesson()
    Task { await brightnessController.settle() }
  }

  /// Same, but awaitable. Applying a preset uses this to finish with one display
  /// before starting the next, so their DDC traffic never overlaps.
  func commitBrightnessAndWait() async {
    await brightnessController.settle()
    await queue?.flush()
  }

  // MARK: - Following the built-in panel

  /// Whether this display tracks the built-in panel — which macOS is already
  /// adjusting to the light in the room.
  var followsBuiltinBrightness: Bool { settings.followsBuiltinBrightness }

  /// The relationship it tracks by. Read by the settings card so it can say
  /// what the mapping currently is rather than only that there is one.
  var followCurve: FollowCurve { settings.followCurve }

  /// Where the source panel is right now.
  ///
  /// Injected by `AppModel` rather than reached for, because the source is one
  /// object shared by every follower and a view model has no business knowing
  /// how it is watched — only what it currently says.
  @ObservationIgnored var sourceBrightness: (@MainActor () -> Double?)?

  /// Switches following on or off, keeping whatever has been taught.
  ///
  /// Deliberately *not* a reset. Turning this off to check something and back on
  /// again is a normal thing to do, and throwing away a relationship that took
  /// two deliberate adjustments to establish would make it one nobody risks
  /// switching off. Retraining is a slider move away.
  func setFollowsBuiltinBrightness(_ isOn: Bool) {
    updateSettings { $0.followsBuiltinBrightness = isOn }
  }

  /// Moves to wherever the curve says this source value belongs.
  ///
  /// Teaches nothing, on purpose: this *is* the curve talking, and a curve that
  /// learned from its own output would walk away from where it was put.
  func applyFollowedBrightness(forSource source: Double) {
    setBrightness(followCurve.target(forSource: source))
  }

  /// Takes the current pair — where the source is, where this display was just
  /// put — as a lesson.
  ///
  /// Trailing, because the callers are a key held down and a slider being
  /// dragged. Every intermediate value is a value on the way somewhere, and
  /// writing a lesson for each of them would spend a preferences encode per key
  /// repeat to record positions nobody chose.
  @ObservationIgnored private var lessonTask: Task<Void, Never>?

  private func scheduleFollowLesson() {
    guard settings.followsBuiltinBrightness else { return }
    lessonTask?.cancel()
    lessonTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self else { return }
      guard let source = self.sourceBrightness?() else { return }
      // `brightness` read here rather than captured: the point of waiting is to
      // record where it came to rest.
      let target = self.brightness
      self.updateSettings { $0.followCurve.learn(source: source, target: target) }
      self.log.record(.info(
        "\(self.name): following \(Int((source * 100).rounded()))% "
          + "→ \(Int((target * 100).rounded()))%"
      ))
    }
  }

  // MARK: - Colour temperature

  /// The chosen white point in Kelvin, or nil for "leave it alone".
  ///
  /// Nil is not 6500. A display at neutral has no gamma table of ours on it at
  /// all, so its own colour profile is doing exactly what it was going to do.
  private(set) var colorTemperatureKelvin: Double?
  private(set) var colorCapabilities: DisplayCapabilities?
  private(set) var isProbingColor = false

  /// The chosen finish, or nil for "leave the tone curve alone".
  ///
  /// Nil rather than `ToneCurve.identity` for the same reason nil is not 6500
  /// above: off means no table of ours on the display, which is a different
  /// state from one holding a curve that happens to be flat.
  private(set) var toneCurve: ToneCurve?

  /// How many times the system has reset our gamma table recently.
  ///
  /// Night Shift writes the same table we do. There is no public way to ask
  /// whether it is on — `CBBlueLightClient` is private and stays unused — so
  /// the app watches for the symptom instead and says what it sees. Counting is
  /// the honest version of guessing.
  private(set) var recentColorResets = 0
  private var lastColorReset: Date?

  var isFightingSomethingOverColor: Bool {
    colorTemperatureKelvin != nil && recentColorResets >= 3
  }

  /// Whether this panel has a colour control of its own that DDC can reach.
  ///
  /// Currently informational only: the white point is applied through the gamma
  /// table either way. Panels that do expose 0x0C do so in coarse steps their
  /// own menu offers, and switching between two mechanisms depending on the
  /// monitor would make the same slider mean different things on two screens.
  var hasNativeColorControl: Bool {
    guard let colorCapabilities else { return false }
    return colorCapabilities.isUsable(.colorTemperature) || colorCapabilities.hasUsableGains
  }

  func setColorTemperature(_ kelvin: Double?) {
    colorTemperatureKelvin = kelvin
    preferences.update(key) { $0.colorTemperatureKelvin = kelvin }
    applyWhitePoint()
    recentColorResets = 0
  }

  private func applyWhitePoint() {
    let point = colorTemperatureKelvin.map { ColorTemperature.whitePoint(kelvin: $0) } ?? .neutral
    GammaDimmer.shared.setWhitePoint(point, for: displayID)
  }

  /// Nil turns the finish off, which takes our curve off the display rather
  /// than writing a flat one over it.
  func setToneCurve(_ curve: ToneCurve?) {
    toneCurve = curve
    preferences.update(key) { $0.toneCurve = curve }
    applyToneCurve()
  }

  private func applyToneCurve() {
    GammaDimmer.shared.setTone(toneCurve ?? .identity, for: displayID)
  }

  /// Called when something outside the app resets the gamma table.
  func noteColorSettingsChanged() {
    guard colorTemperatureKelvin != nil else { return }
    let now = Date()
    // Only count resets that arrive in a burst. One after a wake is normal and
    // means nothing; four in a minute means something else is driving the same
    // table.
    if let lastColorReset, now.timeIntervalSince(lastColorReset) > 60 {
      recentColorResets = 0
    }
    lastColorReset = now
    recentColorResets += 1
  }

  /// Asks the panel what colour features it really has.
  ///
  /// On demand rather than at first contact, and cached against the panel — the
  /// same arrangement as `readCapabilityString()`, for the same reason. Six
  /// round trips is too much to spend at connect time on a card most people
  /// never open.
  func probeColorSupport() async {
    guard colorCapabilities == nil, !isProbingColor, let transport = arm64Transport else { return }
    isProbingColor = true
    defer { isProbingColor = false }

    let timing = settings.timing
    let log = log
    let probed = await Task.detached(priority: .utility) {
      DisplayCapabilities.probe(
        transport: transport, timing: timing, features: VCPCode.colorProbeSet, log: log
      )
    }.value

    colorCapabilities = probed
    preferences.update(key) { $0.colorCapabilities = probed }
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
          // Only the dimming, not `clear(_:)`. The gamma table now carries the
          // colour temperature as well, and changing how brightness is
          // delivered is no reason to throw away a white point the user chose.
          GammaDimmer.shared.setDimming(1.0, for: displayID)
        }
        await brightnessController.reprime()
        brightness = await brightnessController.brightness()
      }
      brightnessStrategy = await brightnessController.effectiveStrategy
    }
  }

  var settings: DisplaySettings { preferences.settings(for: key) }

  // MARK: - Health

  /// Marks are written the instant they are placed rather than on leaving the
  /// overlay, and that is what makes escape safe: the way out of a full-screen
  /// overlay must never be the way to lose what was just done in it.
  func setPixelDefects(_ defects: [PixelDefect]) {
    updateSettings { $0.pixelDefects = defects }
    pixelDefects = defects
  }

  func clearPixelDefects() {
    setPixelDefects([])
  }

  func setHealthReport(_ report: HealthReport) {
    updateSettings { $0.healthReport = report }
    healthReport = report
  }

  /// How long after our own write the cached value is trusted without asking.
  ///
  /// Key repeat runs at roughly 30 ms, and the write is fired at an actor rather
  /// than awaited — so a re-read inside a burst would come back with the value
  /// from before the previous press, and the screen would stop moving under a
  /// held key. Long enough to cover a whole burst, short enough that the next
  /// deliberate press asks again.
  private static let brightnessResyncQuietPeriod: Duration = .milliseconds(500)

  /// Asks the built-in panel where it actually is, before stepping from there.
  ///
  /// The cached value is normally right, because nothing but this app moves an
  /// external display. The built-in panel is the opposite: auto-brightness,
  /// Control Centre, the lid opening and any other app all move it behind our
  /// back, and it is primed exactly once at connect. Stepping from that number
  /// hours later makes the first key press throw the screen somewhere it has
  /// not been all day.
  ///
  /// Only affordable on the native path, and only worth doing there. Native is a
  /// local call into DisplayServices; asking DDC the same question is a round
  /// trip on the I2C bus, per key press, which is the idle cost this app exists
  /// to avoid — see `BrightnessController.prime()`. Gamma needs no asking at
  /// all: the app owns that table outright.
  ///
  /// DisplayServices can also push these changes
  /// (`DisplayServicesRegisterForBrightnessChangeNotifications`), which would
  /// cost nothing while nothing changes and is the better answer if this read
  /// ever proves visible. It is not in the C shim, and adding a private callback
  /// registration is a larger and riskier change than a gated read.
  @discardableResult
  func resyncNativeBrightness() -> Double {
    guard brightnessStrategy == .native else { return brightness }
    if let lastBrightnessWrite,
       ContinuousClock.now - lastBrightnessWrite < Self.brightnessResyncQuietPeriod {
      return brightness
    }
    guard let actual = NativeBrightness.get(displayID) else { return brightness }
    brightness = actual
    return actual
  }

  /// Nudges brightness by a step and returns the new value *synchronously*.
  ///
  /// The caller needs the value right away to render the HUD in the same frame
  /// as the key press. Awaiting the actor first would put the indicator a frame
  /// behind the keyboard, which is exactly the lag people notice — which is also
  /// why the re-sync above is a plain call and not a hop.
  @discardableResult
  func adjustBrightness(by step: Double) -> Double {
    let target = min(1, max(0, resyncNativeBrightness() + step))
    brightness = target
    lastBrightnessWrite = .now
    // Every caller of this — the keys, a hotkey, the scroll wheel — is a person
    // deciding. Presets and the schedule go through `setBrightness` instead, and
    // deliberately teach nothing.
    scheduleFollowLesson()
    Task { await brightnessController.setBrightness(target) }
    return target
  }

  /// Nudges contrast, and returns where it landed — synchronously, for the same
  /// reason `adjustBrightness` does.
  @discardableResult
  func adjustContrast(by step: Double) -> Double {
    let target = min(1, max(0, contrast + step))
    setContrast(target)
    return target
  }

  /// Nudges the white point along the Kelvin scale, and returns the new one —
  /// or nil, which is this control's "off".
  ///
  /// Two rules that are not obvious from the arithmetic:
  ///
  /// **From off, a step starts at neutral.** There is no current value to add
  /// to, and starting at either end would jump the screen a long way for one
  /// press. Neutral is where the scale's own middle is, so the first press moves
  /// exactly one step off it — which is the only reading of "warmer" that is
  /// about the screen you are looking at.
  ///
  /// **Landing on neutral stores nil, not 6500.** Those are the same picture and
  /// not the same state: at neutral there is no table of ours on the display at
  /// all. So walking the warmth all the way back takes it off rather than
  /// leaving one behind that does nothing — the same conversion
  /// `AppModel.applyScheduledValues` makes for a scheduled stop.
  @discardableResult
  func adjustColorTemperature(by step: Double) -> Double? {
    let range = ColorTemperature.range
    let current = colorTemperatureKelvin ?? ColorTemperature.neutralKelvin
    let target = min(range.upperBound, max(range.lowerBound, current + step))
    let settled = abs(target - ColorTemperature.neutralKelvin) < 1 ? nil : target
    setColorTemperature(settled)
    return settled
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
