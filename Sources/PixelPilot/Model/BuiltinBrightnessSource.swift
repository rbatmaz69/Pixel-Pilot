import AppKit
import CoreGraphics
import PixelPilotCore

/// Watches the built-in panel, so other displays can follow it.
///
/// The built-in panel is the signal rather than the ambient light sensor itself,
/// and that is the whole trick. macOS already turns the sensor into a brightness
/// — calibrated, smoothed, and matched to the person's own habits — and
/// `DisplayServicesGetBrightness` reads the result. Going after the sensor
/// directly would mean a second private framework, a raw lux figure nobody has
/// a mapping for, and a curve to maintain that macOS maintains better.
///
/// **Nothing runs until a display asks to follow.** Started, it is either a
/// notification registration, which costs nothing between changes, or — if that
/// registration is not available — a five-second timer, which does not. That
/// second case is the only recurring timer in this application, it exists only
/// while someone is using the feature, and the settings window says so out loud
/// rather than quietly spending it. The same bargain as the HID monitor.
@MainActor
@Observable
final class BuiltinBrightnessSource {
  /// How the value is being obtained, which the UI reports because the two
  /// differ in what they cost.
  enum Mode: Equatable {
    /// Told when it changes. Free while nothing changes.
    case notifications
    /// Asked every `pollInterval`. Not free, and said so.
    case polling
    /// Nothing to watch, or the panel cannot be read.
    case unavailable
  }

  /// Slow on purpose. The room does not get dark in under five seconds, and
  /// every tick here is a wake-up in an app whose measured idle cost is zero.
  static let pollIntervalSeconds = 5

  private(set) var mode: Mode = .unavailable
  /// The last value read, and what a follower is currently being mapped from.
  private(set) var current: Double?
  private(set) var watchedDisplayID: CGDirectDisplayID?

  var isRunning: Bool { watchedDisplayID != nil }

  private let onChange: (Double) -> Void

  /// Rounds up bursts. The sensor drifts continuously and macOS ramps rather
  /// than steps, so a change arrives as a run of them — and each one would
  /// otherwise be a DDC round trip per following display.
  private let debouncer = Debouncer(delay: .milliseconds(250))
  @ObservationIgnored private var pollTimer: DispatchSourceTimer?

  init(onChange: @escaping (Double) -> Void) {
    self.onChange = onChange
  }

  /// Starts watching one display, replacing whatever was being watched before.
  ///
  /// Idempotent for the display already being watched, because the callers are
  /// display reconfiguration and a settings toggle, both of which fire more
  /// often than the answer changes.
  func start(watching displayID: CGDirectDisplayID) {
    guard watchedDisplayID != displayID else { return }
    stop()

    // A panel that cannot be read is not a source. This is the normal answer
    // for an external display, and the reason `AppModel` only ever points this
    // at the built-in one.
    guard NativeBrightness.isSupported(displayID) else {
      mode = .unavailable
      return
    }

    watchedDisplayID = displayID
    current = NativeBrightness.get(displayID)

    let observed = NativeBrightness.observe(displayID) { [weak self] value in
      // Arrives on whatever thread DisplayServices notifies on.
      Task { @MainActor in self?.report(value) }
    }
    if observed {
      mode = .notifications
      return
    }

    startPolling(displayID)
    mode = .polling
  }

  func stop() {
    if let watchedDisplayID {
      NativeBrightness.stopObserving(watchedDisplayID)
    }
    watchedDisplayID = nil
    pollTimer?.cancel()
    pollTimer = nil
    current = nil
    mode = .unavailable

    let debouncer = debouncer
    Task { await debouncer.cancel() }
  }

  /// Re-reads without reporting, for the moments the value may have moved while
  /// nothing was listening — coming back from sleep, most obviously.
  ///
  /// Silent on purpose: waking up is not an ambient change, and pushing a round
  /// of DDC writes into the first second after a wake is exactly when the bus is
  /// least likely to answer.
  func resync() {
    guard let watchedDisplayID else { return }
    current = NativeBrightness.get(watchedDisplayID)
  }

  private func startPolling(_ displayID: CGDirectDisplayID) {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let interval = DispatchTimeInterval.seconds(Self.pollIntervalSeconds)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    // Weakly, so the timer holding its handler does not hold this object: the
    // cycle would otherwise only ever be broken by `stop()` being called.
    timer.setEventHandler { [weak self] in
      guard let value = NativeBrightness.get(displayID) else { return }
      Task { @MainActor in self?.report(value) }
    }
    timer.resume()
    pollTimer = timer
  }

  /// Notes a new value and, if it is genuinely new, schedules the report.
  private func report(_ value: Double) {
    // The notification path filters in C and the poll path does not, so the
    // check lives here where both meet. It is also what stops our own writes
    // echoing back as changes when a following display is itself the built-in
    // one — which cannot happen today, and should still not loop if it did.
    guard abs((current ?? -1) - value) > 0.0001 else { return }
    current = value

    let debouncer = debouncer
    Task { [weak self] in
      await debouncer.trigger {
        await MainActor.run {
          // The latest value, not the one that scheduled this call. Debouncing
          // a ramp and then acting on its first frame would land the followers
          // one step behind where the room actually is.
          guard let self, let latest = self.current else { return }
          self.onChange(latest)
        }
      }
    }
  }
}
