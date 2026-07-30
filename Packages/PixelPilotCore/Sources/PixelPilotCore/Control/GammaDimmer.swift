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
    let scale = clampFraction(fraction)
    let last = Double(entries - 1)
    return (0 ..< entries).map { index in
      CGGammaValue(Double(index) / last * scale)
    }
  }

  static func clampFraction(_ fraction: Double) -> Double {
    min(1.0, max(minimumFraction, fraction))
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
/// **A crash leaves the screen dark.** Anything that dims the display has to
/// guarantee restoration even when it dies badly, so the safety net below is
/// installed the first time dimming is applied.
public final class GammaDimmer: @unchecked Sendable {
  public static let shared = GammaDimmer()

  private let lock = NSLock()
  /// Desired dimming per display. Also the source of truth for reasserting.
  private var fractions: [CGDirectDisplayID: Double] = [:]
  private var safetyNetInstalled = false

  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "gamma")

  public init() {}

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
    lock.unlock()

    apply(clamped, to: displayID)
  }

  public func dimming(for displayID: CGDirectDisplayID) -> Double {
    lock.withLock { fractions[displayID] ?? 1.0 }
  }

  public func clear(_ displayID: CGDirectDisplayID) {
    setDimming(1.0, for: displayID)
  }

  /// Restores every display we touched. Called on quit, and safe to call when
  /// nothing is dimmed.
  public func clearAll() {
    lock.lock()
    let displays = Array(fractions.keys)
    fractions.removeAll()
    lock.unlock()

    for displayID in displays {
      apply(1.0, to: displayID)
    }
    CGDisplayRestoreColorSyncSettings()
  }

  /// Reapplies dimming after something else clobbered the gamma table.
  ///
  /// Drive this from display reconfiguration, wake, and appearance/Night Shift
  /// notifications — never from a timer.
  public func reassertAll() {
    let current = lock.withLock { fractions }
    guard !current.isEmpty else { return }

    for (displayID, fraction) in current {
      apply(fraction, to: displayID)
    }
    logger.debug("Reasserted gamma on \(current.count, privacy: .public) display(s)")
  }

  /// Drops displays that are no longer online, so a disconnected monitor does
  /// not keep a stale entry alive forever.
  public func pruneOffline(onlineDisplayIDs: Set<CGDirectDisplayID>) {
    lock.withLock {
      fractions = fractions.filter { onlineDisplayIDs.contains($0.key) }
    }
  }

  // MARK: - Applying

  private func apply(_ fraction: Double, to displayID: CGDirectDisplayID) {
    guard fraction < 1.0 else {
      CGDisplayRestoreColorSyncSettings()
      return
    }

    let ramp = GammaRamp.linear(fraction: fraction)
    let result = ramp.withUnsafeBufferPointer { buffer -> CGError in
      guard let base = buffer.baseAddress else { return .failure }
      // The same ramp for all three channels: this is a luminance change, not a
      // colour correction.
      return CGSetDisplayTransferByTable(displayID, UInt32(buffer.count), base, base, base)
    }

    if result != .success {
      logger.error("CGSetDisplayTransferByTable failed for \(displayID, privacy: .public): \(result.rawValue)")
    }
  }

  // MARK: - Safety net

  /// Installed lazily, the first time anything is actually dimmed — an app that
  /// never dims should not be registering process-wide handlers.
  ///
  /// Caller must hold `lock`.
  private func installSafetyNetLocked() {
    guard !safetyNetInstalled else { return }
    safetyNetInstalled = true

    atexit {
      CGDisplayRestoreColorSyncSettings()
    }

    // Strictly speaking CGDisplayRestoreColorSyncSettings is not
    // async-signal-safe, so this is a calculated risk: the alternative to
    // possibly misbehaving inside a handler we are already crashing in is
    // definitely leaving the user with a black screen.
    for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS] {
      signal(signalNumber) { received in
        CGDisplayRestoreColorSyncSettings()
        signal(received, SIG_DFL)
        raise(received)
      }
    }

    logger.debug("Gamma restoration safety net installed")
  }
}
