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

  /// Luminance, colour, finish and veil, in one set of ramps.
  ///
  /// Composition falls out of multiplication, which is the whole reason
  /// warming and dimming can coexist without either fighting the other:
  /// dimming to 60 % at 3000 K is the 3000 K white point scaled by 0.6, and the
  /// order the two were asked for makes no difference. The tone curve and the
  /// veil join on the same terms.
  ///
  /// A neutral white point, an identity tone curve and a veil of 1 reproduce
  /// `linear` exactly, which is what lets the existing dimming tests keep
  /// pinning the luminance behaviour unchanged.
  ///
  /// **The floor covers luminance and veil together.** Flooring the luminance
  /// on its own and then multiplying the veil into it afterwards would put a
  /// display at minimum brightness well below the level that floor exists to
  /// guarantee — the veil would have quietly reopened the lockout the floor was
  /// added to close.
  ///
  /// One consequence worth naming, because it looks like a bug and is not: the
  /// white point scales each channel differently, so a lifted black picks up
  /// the warm cast at 3000 K rather than staying neutral grey. That is what
  /// paper under a warm lamp does, and the alternative — a neutral floor under
  /// a warm picture — is the thing that would look wrong.
  static func channels(
    luminance: Double, whitePoint: WhitePoint, tone: ToneCurve = .identity,
    veil: Double = 1.0, entries: Int = entryCount
  ) -> (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
    let scale = clampFraction(luminance * min(1, max(0, veil)))
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
  /// How far each display is pushed back for not being the one being worked on.
  ///
  /// A fourth dictionary and not a second use of `fractions`, and the reason is
  /// load-bearing rather than tidiness: `BrightnessController` reads
  /// `dimming(for:)` back out of here to answer what a gamma-dimmed display is
  /// currently set to. Folding the veil in there would move the brightness
  /// slider every time the user changed window, and a preset captured while a
  /// screen happened to be unfocused would record the veiled value as that
  /// display's brightness. Kept apart, the veil is invisible to everything that
  /// asks what the display is set to — which is exactly what it should be.
  private var veils: [CGDirectDisplayID: Double] = [:]
  /// Displays whose tables are held back without being forgotten. See `suspend`.
  private var suspended: Set<CGDirectDisplayID> = []
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

  /// Displays currently pushed back for not being worked on.
  public var veiledDisplays: Set<CGDirectDisplayID> {
    lock.withLock { Set(veils.keys) }
  }

  /// Every display this dimmer is holding something on, of any kind.
  private var touchedDisplaysLocked: Set<CGDirectDisplayID> {
    Set(fractions.keys).union(whitePoints.keys).union(tones.keys).union(veils.keys)
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

  /// `1.0` lifts the veil. Lower values push the display back.
  ///
  /// Separate from `setDimming` on purpose — see `veils`. It composes with
  /// everything else by the same multiplication, so a veiled display keeps its
  /// warmth, its finish and the brightness it was set to; it is simply further
  /// away.
  public func setVeil(_ fraction: Double, for displayID: CGDirectDisplayID) {
    let clamped = min(1, max(0, fraction))

    lock.lock()
    if clamped >= 1.0 {
      veils.removeValue(forKey: displayID)
    } else {
      veils[displayID] = clamped
      installSafetyNetLocked()
    }
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  public func tone(for displayID: CGDirectDisplayID) -> ToneCurve {
    lock.withLock { tones[displayID] ?? .identity }
  }

  public func veil(for displayID: CGDirectDisplayID) -> Double {
    lock.withLock { veils[displayID] ?? 1.0 }
  }

  /// Drops everything this dimmer is holding on one display.
  public func clear(_ displayID: CGDirectDisplayID) {
    lock.lock()
    fractions.removeValue(forKey: displayID)
    whitePoints.removeValue(forKey: displayID)
    tones.removeValue(forKey: displayID)
    veils.removeValue(forKey: displayID)
    suspended.remove(displayID)
    lock.unlock()

    apply(
      (luminance: 1.0, whitePoint: .neutral, tone: .identity, veil: 1.0, isSuspended: false),
      to: displayID
    )
  }

  /// Restores every display we touched. Called on quit, and safe to call when
  /// nothing is dimmed.
  public func clearAll() {
    lock.lock()
    let displays = touchedDisplaysLocked
    fractions.removeAll()
    whitePoints.removeAll()
    tones.removeAll()
    veils.removeAll()
    suspended.removeAll()
    lock.unlock()

    for displayID in displays {
      apply(
        (luminance: 1.0, whitePoint: .neutral, tone: .identity, veil: 1.0, isSuspended: false),
        to: displayID
      )
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

  // MARK: - Suspending

  /// Takes our tables off a display without forgetting what they were.
  ///
  /// For showing the panel as macOS hands it over — a test pattern looked at
  /// through a lifted tone curve is a lie about the panel, not a measurement of
  /// it. `clear(_:)` is the wrong tool: it would take the user's warmth and
  /// finish with it and there would be nothing to put back.
  ///
  /// A suspended display is still reasserted *through* — `reassertAll` runs the
  /// same `apply`, which sees the suspension and hands the table back again.
  /// That matters because the events reassertion answers, a wake or a colour
  /// profile change, do not stop happening because a test pattern is up.
  public func suspend(_ displayID: CGDirectDisplayID) {
    lock.lock()
    suspended.insert(displayID)
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  public func resume(_ displayID: CGDirectDisplayID) {
    lock.lock()
    suspended.remove(displayID)
    let state = stateLocked(for: displayID)
    lock.unlock()

    apply(state, to: displayID)
  }

  public func isSuspended(_ displayID: CGDirectDisplayID) -> Bool {
    lock.withLock { suspended.contains(displayID) }
  }

  /// Drops displays that are no longer online, so a disconnected monitor does
  /// not keep a stale entry alive forever.
  public func pruneOffline(onlineDisplayIDs: Set<CGDirectDisplayID>) {
    lock.withLock {
      fractions = fractions.filter { onlineDisplayIDs.contains($0.key) }
      whitePoints = whitePoints.filter { onlineDisplayIDs.contains($0.key) }
      tones = tones.filter { onlineDisplayIDs.contains($0.key) }
      veils = veils.filter { onlineDisplayIDs.contains($0.key) }
      suspended = suspended.filter { onlineDisplayIDs.contains($0) }
    }
  }

  // MARK: - Applying

  private typealias GammaState = (
    luminance: Double, whitePoint: WhitePoint, tone: ToneCurve, veil: Double, isSuspended: Bool
  )

  /// Caller must hold `lock`.
  private func stateLocked(for displayID: CGDirectDisplayID) -> GammaState {
    (
      fractions[displayID] ?? 1.0,
      whitePoints[displayID] ?? .neutral,
      tones[displayID] ?? .identity,
      veils[displayID] ?? 1.0,
      suspended.contains(displayID)
    )
  }

  private func apply(_ state: GammaState, to displayID: CGDirectDisplayID) {
    // Nothing to hold means hand the table back rather than writing an identity
    // ramp over it — the system's own profile is not necessarily linear, and
    // "restore" is the only way to return whatever it really was. A suspended
    // display takes the same path for the same reason: it is being shown as
    // macOS hands it over, which is what "restore" means.
    //
    // All four conditions, not three: a display carrying only a veil is a
    // display holding something, and leaving one of these out restores the
    // system profile over it on every single write — which fails as "the
    // setting does nothing" rather than as anything anyone could debug.
    guard !state.isSuspended,
          state.luminance < 1.0 || !state.whitePoint.isNeutral || !state.tone.isIdentity
          || state.veil < 1.0
    else {
      backend.restore(displayID)
      // `CGDisplayRestoreColorSyncSettings` has no per-display form — the
      // backend says so itself — so that call just handed *every* display back,
      // not the one asked for. Anything still being held elsewhere has this
      // instant been wiped off the screen and has to be put back.
      //
      // This is the bug that made attention look broken. Clearing one display's
      // veil and setting another's happens in the same pass, dictionary order
      // is unspecified, and when the clear landed second it erased the veil
      // written a microsecond earlier — so the feature worked or did not
      // depending on a hash seed that changes every launch. It was always
      // latent: warming one display and un-warming another had the same race,
      // just far too rarely to catch.
      reassertOthers(excluding: displayID)
      return
    }
    write(state, to: displayID)
  }

  private func write(_ state: GammaState, to displayID: CGDirectDisplayID) {
    let ramps = GammaRamp.channels(
      luminance: state.luminance, whitePoint: state.whitePoint, tone: state.tone, veil: state.veil
    )
    backend.applyRamps(red: ramps.red, green: ramps.green, blue: ramps.blue, to: displayID)
  }

  /// Re-writes every other display we are holding something on.
  ///
  /// Writes directly rather than going back through `apply`, which cannot
  /// recurse into another restore — every display in `touchedDisplays` holds
  /// something by construction, since the setters drop the key when a value
  /// becomes the identity — but going straight to the write says so rather than
  /// relying on it.
  private func reassertOthers(excluding displayID: CGDirectDisplayID) {
    let states: [(CGDirectDisplayID, GammaState)] = lock.withLock {
      touchedDisplaysLocked
        .filter { $0 != displayID }
        .map { ($0, stateLocked(for: $0)) }
    }
    // A suspended display is deliberately showing the system's own profile, and
    // the global restore has just given it exactly that. Leave it alone.
    for (id, state) in states where !state.isSuspended {
      write(state, to: id)
    }
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
