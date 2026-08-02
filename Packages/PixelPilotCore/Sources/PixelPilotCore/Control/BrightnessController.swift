import CDDCPrivate
import CoreGraphics
import Foundation

/// Splits a single 0...1 brightness value across the DDC backlight and the gamma
/// table.
///
/// Pure and separated from the controller so the arithmetic — the part that is
/// easy to get subtly wrong and hard to notice — is testable without hardware.
public enum BrightnessMapping {
  /// Where the handover happens when extra dimming is on. Below this point the
  /// backlight is already at its minimum and further darkening comes from gamma.
  public static let extraDimmingSplit: Double = 0.25

  public struct Split: Equatable, Sendable {
    /// 0...1 of the DDC luminance range.
    public let ddcFraction: Double
    /// 1.0 means no gamma dimming.
    public let gammaFraction: Double
  }

  /// - Parameter extraDimming: when false the whole slider drives DDC and gamma
  ///   stays out of the picture entirely.
  public static func split(brightness: Double, extraDimming: Bool) -> Split {
    let value = min(1.0, max(0.0, brightness))

    guard extraDimming else {
      return Split(ddcFraction: value, gammaFraction: 1.0)
    }

    if value >= extraDimmingSplit {
      // Rescale the upper part of the slider onto the full DDC range, so the
      // backlight still reaches maximum at the top.
      let rescaled = (value - extraDimmingSplit) / (1.0 - extraDimmingSplit)
      return Split(ddcFraction: rescaled, gammaFraction: 1.0)
    }

    // Backlight bottomed out; gamma carries the rest down to the floor.
    let position = value / extraDimmingSplit
    let gamma = GammaRamp.minimumFraction
      + position * (1.0 - GammaRamp.minimumFraction)
    return Split(ddcFraction: 0.0, gammaFraction: gamma)
  }
}

/// Native brightness for Apple's own panels, via DisplayServices.
public enum NativeBrightness {
  public static var isAvailable: Bool { PPNativeBrightnessAvailable() }

  public static func isSupported(_ displayID: CGDirectDisplayID) -> Bool {
    PPNativeBrightnessSupported(displayID)
  }

  public static func get(_ displayID: CGDirectDisplayID) -> Double? {
    var value: Float = 0
    guard PPNativeBrightnessGet(displayID, &value) else { return nil }
    return Double(value)
  }

  @discardableResult
  public static func set(_ displayID: CGDirectDisplayID, to fraction: Double) -> Bool {
    PPNativeBrightnessSet(displayID, Float(fraction))
  }

  // MARK: - Watching

  /// Whether a display can be watched for changes, as opposed to asked on a
  /// timer. See the header note in `CDDCPrivate.h` for how little of the
  /// undocumented signature this actually depends on.
  public static var canObserve: Bool { PPNativeBrightnessCanObserve() }

  /// Where an observation is delivered.
  ///
  /// A global rather than a stored closure, because a C function pointer cannot
  /// capture: the trampoline handed to DisplayServices has to be a plain
  /// function, so the only way back to Swift state is a value it can reach
  /// without a context. There is one watcher in this app, and this is it.
  private static let sink = ObservationSink()

  private final class ObservationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [CGDirectDisplayID: @Sendable (Double) -> Void] = [:]

    func set(_ handler: (@Sendable (Double) -> Void)?, for displayID: CGDirectDisplayID) {
      lock.withLock { handlers[displayID] = handler }
    }

    func deliver(_ displayID: CGDirectDisplayID, _ value: Double) {
      guard let handler = lock.withLock({ handlers[displayID] }) else { return }
      handler(value)
    }
  }

  /// Starts watching one display. The handler **arrives on an arbitrary
  /// thread** — whatever thread DisplayServices happens to notify on.
  ///
  /// Returns false when watching is not possible at all, which is the caller's
  /// signal to fall back to asking on a timer.
  public static func observe(
    _ displayID: CGDirectDisplayID,
    handler: @escaping @Sendable (Double) -> Void
  ) -> Bool {
    sink.set(handler, for: displayID)
    let started = PPNativeBrightnessObserve(displayID) { displayID, value in
      NativeBrightness.sink.deliver(displayID, Double(value))
    }
    if !started { sink.set(nil, for: displayID) }
    return started
  }

  public static func stopObserving(_ displayID: CGDirectDisplayID) {
    PPNativeBrightnessStopObserving(displayID)
    sink.set(nil, for: displayID)
  }
}

/// Drives brightness for one display, choosing how to get there.
///
/// The point of this type is that the rest of the app — sliders, media keys,
/// hotkeys — deals in a single 0...1 number and never has to know whether that
/// number becomes a DDC packet, a DisplayServices call or a gamma ramp.
public actor BrightnessController {
  public let displayID: CGDirectDisplayID
  public let key: DisplayKey

  private let queue: DDCQueue?
  private let gamma: GammaDimmer
  private let isBuiltin: Bool
  private let log: DiagnosticsLog?

  private var settings: DisplaySettings
  /// Cached DDC maximum for luminance, learned at priming. Most panels use 100,
  /// but assuming that would quietly halve or double the range on the ones that
  /// do not.
  private var ddcMaximum: UInt16 = 100
  private var currentBrightness: Double = 1.0
  private var hasPrimed = false

  public init(
    display: DiscoveredDisplay,
    queue: DDCQueue?,
    settings: DisplaySettings,
    gamma: GammaDimmer = .shared,
    log: DiagnosticsLog? = nil
  ) {
    self.displayID = display.displayID
    self.key = display.key
    self.isBuiltin = display.isBuiltin
    self.queue = queue
    self.settings = settings
    self.gamma = gamma
    self.log = log
  }

  // MARK: - Strategy

  /// What `automatic` resolves to for this display, in preference order:
  /// native for Apple's own panels, DDC when the panel really supports
  /// luminance, gamma otherwise.
  public var effectiveStrategy: BrightnessStrategy {
    switch settings.brightnessStrategy {
    case .automatic:
      if isBuiltin, NativeBrightness.isSupported(displayID) { return .native }
      if queue != nil, settings.capabilities?.isUsable(.luminance) == true { return .ddc }
      return .gamma
    case let explicit:
      return explicit
    }
  }

  public func updateSettings(_ newSettings: DisplaySettings) {
    settings = newSettings
  }

  /// Reads the display again after the strategy changed.
  ///
  /// The paths do not share a value: DDC luminance and the gamma table are
  /// independent, so after a switch the only honest thing is to ask the new one
  /// where it actually is.
  public func reprime() async {
    hasPrimed = false
    await prime()
  }

  public func brightness() -> Double { currentBrightness }

  // MARK: - Priming

  /// Reads the display's current state once, at connect.
  ///
  /// This is the only read. Afterwards the value lives in memory and is written
  /// but never polled — polling a DDC bus in the background is precisely the
  /// idle drain this app exists to avoid.
  public func prime() async {
    guard !hasPrimed else { return }
    hasPrimed = true

    switch effectiveStrategy {
    case .native:
      currentBrightness = NativeBrightness.get(displayID) ?? 1.0

    case .ddc:
      guard let queue else { break }
      if let reading = try? await queue.read(.luminance), reading.maximum > 0 {
        ddcMaximum = reading.maximum
        currentBrightness = Double(reading.current) / Double(reading.maximum)
      } else {
        log?.record(.warning("Could not prime brightness for \(key); assuming full"))
      }

    case .gamma:
      currentBrightness = gamma.dimming(for: displayID)

    case .automatic:
      break // resolved above; unreachable
    }

    log?.record(.info("Primed \(key) at \(Int(currentBrightness * 100))% via \(effectiveStrategy.displayName)"))
  }

  // MARK: - Setting

  /// Sets brightness as a 0...1 fraction. Returns immediately; DDC traffic is
  /// throttled and coalesced by `DDCQueue`.
  public func setBrightness(_ fraction: Double) async {
    let value = min(1.0, max(0.0, fraction))
    currentBrightness = value

    switch effectiveStrategy {
    case .native:
      NativeBrightness.set(displayID, to: value)

    case .ddc:
      let split = BrightnessMapping.split(
        brightness: value, extraDimming: settings.extraDimmingEnabled
      )
      await queue?.set(.luminance, value: UInt16((split.ddcFraction * Double(ddcMaximum)).rounded()))
      // Only touch gamma when extra dimming is actually in play, so screenshots
      // and colour accuracy are left alone in the normal case.
      if settings.extraDimmingEnabled {
        gamma.setDimming(split.gammaFraction, for: displayID)
      }

    case .gamma:
      gamma.setDimming(value, for: displayID)

    case .automatic:
      break
    }
  }

  /// Nudges brightness by `step`, for a key press. Returns the new value so the
  /// caller can show it without a round trip.
  @discardableResult
  public func adjustBrightness(by step: Double) async -> Double {
    let target = currentBrightness + step
    await setBrightness(target)
    return currentBrightness
  }

  /// Writes the pending value once more with verification, for the end of a
  /// drag. Failure here is informational — the coalesced write already happened.
  public func settle() async {
    guard effectiveStrategy == .ddc, let queue else { return }
    await queue.flush()
  }
}
