import CoreGraphics
import Foundation
import os

/// The pure maths behind software dimming, separated so it can be tested
/// without touching a display.
enum GammaRamp {
  /// Never dim completely. A user who drags to zero on their only display and
  /// cannot see the screen to drag back has been locked out of their Mac.
  static let minimumFraction: Double = 0.08

  static let entryCount = 256

  /// A linear ramp scaled by `fraction`, where 1.0 is the identity.
  static func linear(fraction: Double, entries: Int = entryCount) -> [CGGammaValue] {
    ramp(scale: clampFraction(fraction), entries: entries)
  }

  /// The ramp itself, without the "never go fully dark" floor.
  ///
  /// Separate because that floor protects a *display*, not a channel. A blue
  /// channel at 0.3 is what 3000 K looks like; clamping it up to the floor
  /// would quietly change the colour that was asked for. The floor still
  /// applies to luminance, and a white point is normalised so one channel is
  /// always at full — so nothing here can black out a screen either.
  ///
  /// `tone` reshapes the ramp before the scale is applied, which is what turns
  /// a display into something that reads like paper. It is the identity by
  /// default and the identity reproduces the plain scaled ramp exactly, so a
  /// caller that never heard of tone curves gets what it always got.
  ///
  /// Applying the scale *after* the curve also scales the lifted black, and
  /// that is the behaviour that is wanted: a floor that stayed put as the
  /// display dimmed would end up swamping the picture at low brightness.
  private static func ramp(
    scale: Double, tone: ToneCurve = .identity, entries: Int
  ) -> [CGGammaValue] {
    let last = Double(entries - 1)
    let clamped = min(1, max(0, scale))
    return (0 ..< entries).map { index in
      CGGammaValue(tone.value(at: Double(index) / last) * clamped)
    }
  }

  static func clampFraction(_ fraction: Double) -> Double {
    min(1.0, max(minimumFraction, fraction))
  }

  /// Luminance, colour and finish, in one set of ramps.
  ///
  /// Composition falls out of multiplication, which is the whole reason
  /// warming and dimming can coexist without either fighting the other:
  /// dimming to 60 % at 3000 K is the 3000 K white point scaled by 0.6, and the
  /// order the two were asked for makes no difference. The tone curve joins on
  /// the same terms.
  ///
  /// A neutral white point and an identity tone curve reproduce `linear`
  /// exactly, which is what lets the existing dimming tests keep pinning the
  /// luminance behaviour unchanged.
  ///
  /// One consequence worth naming, because it looks like a bug and is not: the
  /// white point scales each channel differently, so a lifted black picks up
  /// the warm cast at 3000 K rather than staying neutral grey. That is what
  /// paper under a warm lamp does, and the alternative — a neutral floor under
  /// a warm picture — is the thing that would look wrong.
  static func channels(
    luminance: Double, whitePoint: WhitePoint, tone: ToneCurve = .identity,
    entries: Int = entryCount
  ) -> (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
    let scale = clampFraction(luminance)
    return (
      red: ramp(scale: scale * whitePoint.red, tone: tone, entries: entries),
      green: ramp(scale: scale * whitePoint.green, tone: tone, entries: entries),
      blue: ramp(scale: scale * whitePoint.blue, tone: tone, entries: entries)
    )
  }

  static var isIdentity: (Double) -> Bool {
    { $0 >= 1.0 }
  }
}

/// Software dimming via the display's gamma table.
///
/// This is the fallback for panels with no DDC path, and the mechanism behind
/// "extra dim" below DDC zero. It does not touch the backlight — it rescales
/// output values — so it costs contrast and is visible in screenshots. That is
/// why it is a fallback and not the default.
///
/// Two things make this harder than it looks:
///
/// **Other software resets it.** Night Shift, True Tone, colour profile changes
/// and display reconfiguration all reset the gamma table. The fix is to reassert
/// on those events — `reassertAll()` — and explicitly *not* to poll for it. A
/// timer checking gamma state several times a second is exactly the kind of
/// idle drain this app is supposed to avoid.
///
/// **A crash does not leave the screen dark** — verified, not assumed. The
/// window server ties the gamma table to the client connection that set it and
/// reverts to identity when that connection dies. Tested by dimming to 85%,
/// sending SIGKILL so no handler of ours could possibly run, and reading the
/// table back: it was identity again.
///
/// That measurement removed code rather than adding it. An earlier version
/// installed handlers for SIGSEGV, SIGABRT, SIGBUS and friends that called
/// `CGDisplayRestoreColorSyncSettings`, which is not async-signal-safe — a real
/// risk of hanging inside a crash we were already having, in exchange for a
/// guarantee the system was already making. `atexit` is kept because it runs in
/// ordinary context and costs nothing.
public final class GammaDimmer: @unchecked Sendable {
  public static let shared = GammaDimmer()

  /// What actually touches the display.
  ///
  /// Separated so the bookkeeping — which displays are dimmed, what survives a
  /// reconfiguration, what gets restored — can be tested without darkening a
  /// real screen. That bookkeeping is the part where a mistake leaves someone
  /// staring at a black monitor, so it is the part that needs tests.
  public protocol Backend: Sendable {
    /// Three ramps, because this is now a luminance *and* colour change. The
    /// single-ramp form below is the special case where all three are equal.
    func applyRamps(
      red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue],
      to displayID: CGDirectDisplayID
    )
    func restore(_ displayID: CGDirectDisplayID)
    func restoreAll()
  }

  struct CoreGraphicsBackend: Backend {
    private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "gamma")

    func applyRamps(
      red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue],
      to displayID: CGDirectDisplayID
    ) {
      let result = red.withUnsafeBufferPointer { redBuffer -> CGError in
        green.withUnsafeBufferPointer { greenBuffer -> CGError in
          blue.withUnsafeBufferPointer { blueBuffer -> CGError in
            guard let r = redBuffer.baseAddress,
                  let g = greenBuffer.baseAddress,
                  let b = blueBuffer.baseAddress
            else { return .failure }
            return CGSetDisplayTransferByTable(displayID, UInt32(redBuffer.count), r, g, b)
          }
        }
      }
      if result != .success {
        logger.error(
          "CGSetDisplayTransferByTable failed for \(displayID, privacy: .public): \(result.rawValue)"
        )
      }
    }

    func restore(_ displayID: CGDirectDisplayID) {
      // CoreGraphics has no per-display restore; this is the only lever.
      CGDisplayRestoreColorSyncSettings()
    }

    func restoreAll() {
      CGDisplayRestoreColorSyncSettings()
    }
  }

  private let backend: any Backend
  private let lock = NSLock()
  /// Desired dimming per display. Also the source of truth for reasserting.
  private var fractions: [CGDirectDisplayID: Double] = [:]
  /// Desired colour per display, kept separately for the same reason: both have
  /// to survive a wake, a colour profile change and a Night Shift transition,
  /// and `reassertAll` can only restore what it still knows.
  private var whitePoints: [CGDirectDisplayID: WhitePoint] = [:]
  /// Desired finish per display. A third dictionary rather than a field on one
  /// of the other two, for the third time for the same reason: these three are
  /// set independently, and folding two of them together would mean one could
  /// not be changed without restating the other.
  private var tones: [CGDirectDisplayID: ToneCurve] = [:]
  private var safetyNetInstalled = false

  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "gamma")

  public init(backend: (any Backend)? = nil) {
    self.backend = backend ?? CoreGraphicsBackend()
  }

  /// Displays currently dimmed, for tests and diagnostics.
  public var dimmedDisplays: Set<CGDirectDisplayID> {
    lock.withLock { Set(fractions.keys) }
  }

  /// Displays currently carrying a colour cast.
  public var tintedDisplays: Set<CGDirectDisplayID> {
    lock.withLock { Set(whitePoints.keys) }
  }

  /// Displays currently carrying a finish.
  public var finishedDisplays: Set<CGDirectDisplayID> {
    lock.withLock { Set(tones.keys) }
  }

  /// Every display this dimmer is holding something on, of any kind.
  private var touchedDisplaysLocked: Set<CGDirectDisplayID> {
    Set(fractions.keys).union(whitePoints.keys).union(tones.keys)
  }

  /// `fraction` of 1.0 removes dimming; lower values darken. Values below the
  /// floor are clamped rather than rejected.
  public func setDimming(_ fraction: Double, for displayID: CGDirectDisplayID) {
    let clamped = GammaRamp.clampFraction(fraction)

    lock.lock()
    if clamped >= 1.0 {
      fractions.removeValue(forKey: displayID)
    } else {
      fractions[displayID] = clamped
      installSafetyNetLocked()
    }
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  /// `.neutral` removes the cast.
  ///
  /// Composes with dimming rather than replacing it: the two are multiplied,
  /// so the order they were asked for makes no difference and neither has to
  /// know about the other.
  public func setWhitePoint(_ whitePoint: WhitePoint, for displayID: CGDirectDisplayID) {
    lock.lock()
    if whitePoint.isNeutral {
      whitePoints.removeValue(forKey: displayID)
    } else {
      whitePoints[displayID] = whitePoint
      installSafetyNetLocked()
    }
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  /// `.identity` removes the finish.
  ///
  /// Composes with both of the above by the same multiplication, so a display
  /// can be dimmed, warmed and given a paper finish in any order and end up in
  /// the same place.
  public func setTone(_ tone: ToneCurve, for displayID: CGDirectDisplayID) {
    lock.lock()
    if tone.isIdentity {
      tones.removeValue(forKey: displayID)
    } else {
      tones[displayID] = tone
      installSafetyNetLocked()
    }
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  public func dimming(for displayID: CGDirectDisplayID) -> Double {
    lock.withLock { fractions[displayID] ?? 1.0 }
  }

  public func whitePoint(for displayID: CGDirectDisplayID) -> WhitePoint {
    lock.withLock { whitePoints[displayID] ?? .neutral }
  }

  public func tone(for displayID: CGDirectDisplayID) -> ToneCurve {
    lock.withLock { tones[displayID] ?? .identity }
  }

  /// Drops the dimming, the cast and the finish for one display.
  public func clear(_ displayID: CGDirectDisplayID) {
    lock.lock()
    fractions.removeValue(forKey: displayID)
    whitePoints.removeValue(forKey: displayID)
    tones.removeValue(forKey: displayID)
    lock.unlock()

    apply((luminance: 1.0, whitePoint: .neutral, tone: .identity), to: displayID)
  }

  /// Restores every display we touched. Called on quit, and safe to call when
  /// nothing is dimmed.
  public func clearAll() {
    lock.lock()
    let displays = touchedDisplaysLocked
    fractions.removeAll()
    whitePoints.removeAll()
    tones.removeAll()
    lock.unlock()

    for displayID in displays {
      apply((luminance: 1.0, whitePoint: .neutral, tone: .identity), to: displayID)
    }
    backend.restoreAll()
  }

  /// Reapplies dimming after something else clobbered the gamma table.
  ///
  /// Drive this from display reconfiguration, wake, and appearance/Night Shift
  /// notifications — never from a timer.
  public func reassertAll() {
    let states: [CGDirectDisplayID: GammaState] = lock.withLock {
      Dictionary(uniqueKeysWithValues: touchedDisplaysLocked.map { ($0, stateLocked(for: $0)) })
    }
    guard !states.isEmpty else { return }

    for (displayID, state) in states {
      apply(state, to: displayID)
    }
    logger.debug("Reasserted gamma on \(states.count, privacy: .public) display(s)")
  }

  /// Drops displays that are no longer online, so a disconnected monitor does
  /// not keep a stale entry alive forever.
  public func pruneOffline(onlineDisplayIDs: Set<CGDirectDisplayID>) {
    lock.withLock {
      fractions = fractions.filter { onlineDisplayIDs.contains($0.key) }
      whitePoints = whitePoints.filter { onlineDisplayIDs.contains($0.key) }
      tones = tones.filter { onlineDisplayIDs.contains($0.key) }
    }
  }

  // MARK: - Applying

  private typealias GammaState = (luminance: Double, whitePoint: WhitePoint, tone: ToneCurve)

  /// Caller must hold `lock`.
  private func stateLocked(for displayID: CGDirectDisplayID) -> GammaState {
    (fractions[displayID] ?? 1.0, whitePoints[displayID] ?? .neutral, tones[displayID] ?? .identity)
  }

  private func apply(_ state: GammaState, to displayID: CGDirectDisplayID) {
    // Nothing to hold means hand the table back rather than writing an identity
    // ramp over it — the system's own profile is not necessarily linear, and
    // "restore" is the only way to return whatever it really was.
    //
    // All three conditions, not two: a display carrying only a finish is a
    // display holding something, and leaving the tone out here would restore
    // the system profile over it on every single write.
    guard state.luminance < 1.0 || !state.whitePoint.isNeutral || !state.tone.isIdentity else {
      backend.restore(displayID)
      return
    }
    let ramps = GammaRamp.channels(
      luminance: state.luminance, whitePoint: state.whitePoint, tone: state.tone
    )
    backend.applyRamps(red: ramps.red, green: ramps.green, blue: ramps.blue, to: displayID)
  }

  // MARK: - Safety net

  /// Installed lazily, the first time anything is actually dimmed — an app that
  /// never dims should not be registering process-wide handlers.
  ///
  /// Only `atexit`, deliberately. Signal handlers were removed after testing
  /// showed the window server already restores gamma when the process dies; see
  /// the type documentation. This remains for the orderly-exit path, where it
  /// runs in normal context and restores a moment sooner than the system would.
  ///
  /// Caller must hold `lock`.
  private func installSafetyNetLocked() {
    guard !safetyNetInstalled else { return }
    safetyNetInstalled = true

    atexit {
      CGDisplayRestoreColorSyncSettings()
    }

    logger.debug("Gamma restoration safety net installed")
  }
}
