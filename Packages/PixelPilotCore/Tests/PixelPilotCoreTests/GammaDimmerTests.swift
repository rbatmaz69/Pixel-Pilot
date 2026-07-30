import CoreGraphics
import Foundation
import Testing

@testable import PixelPilotCore

/// Records what would have been sent to the displays.
private final class RecordingBackend: GammaDimmer.Backend, @unchecked Sendable {
  private let lock = NSLock()
  private var _applied: [(display: CGDirectDisplayID, peak: Double)] = []
  private var _restored: [CGDirectDisplayID] = []
  private var _restoreAllCount = 0

  var applied: [(display: CGDirectDisplayID, peak: Double)] { lock.withLock { _applied } }
  var restored: [CGDirectDisplayID] { lock.withLock { _restored } }
  var restoreAllCount: Int { lock.withLock { _restoreAllCount } }

  /// The last ramp peak per display — what the screen would actually be at.
  func peak(for display: CGDirectDisplayID) -> Double? {
    lock.withLock { _applied.last { $0.display == display }?.peak }
  }

  func applyRamp(_ ramp: [CGGammaValue], to displayID: CGDirectDisplayID) {
    lock.withLock { _applied.append((displayID, Double(ramp.last ?? 0))) }
  }

  func restore(_ displayID: CGDirectDisplayID) {
    lock.withLock { _restored.append(displayID) }
  }

  func restoreAll() {
    lock.withLock { _restoreAllCount += 1 }
  }
}

@Suite("Gamma dimmer")
struct GammaDimmerTests {
  private let displayA: CGDirectDisplayID = 1
  private let displayB: CGDirectDisplayID = 2

  @Test("Dimming reaches the display and is remembered")
  func appliesAndRecords() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.5, for: displayA)

    #expect(dimmer.dimming(for: displayA) == 0.5)
    #expect(dimmer.dimmedDisplays == [displayA])
    #expect(abs((backend.peak(for: displayA) ?? 0) - 0.5) < 0.001)
  }

  @Test("Restoring a display drops it from the books")
  func clearRemovesDisplay() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.4, for: displayA)
    dimmer.clear(displayA)

    #expect(dimmer.dimmedDisplays.isEmpty)
    #expect(dimmer.dimming(for: displayA) == 1.0)
    #expect(backend.restored.contains(displayA))
  }

  /// Night Shift, a colour profile change or a reconfiguration wipes the gamma
  /// table. Reasserting is how dimming survives that, and it must reapply every
  /// display — not just the last one touched.
  @Test("Reasserting reapplies every dimmed display")
  func reassertsAll() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.5, for: displayA)
    dimmer.setDimming(0.3, for: displayB)
    dimmer.reassertAll()

    #expect(abs((backend.peak(for: displayA) ?? 0) - 0.5) < 0.001)
    #expect(abs((backend.peak(for: displayB) ?? 0) - 0.3) < 0.001)
    #expect(backend.applied.filter { $0.display == displayA }.count == 2)
  }

  @Test("Reasserting with nothing dimmed touches no display")
  func reassertIsQuietWhenNothingDimmed() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.reassertAll()
    #expect(backend.applied.isEmpty)
  }

  /// A monitor unplugged while dimmed would otherwise keep an entry forever,
  /// and be reasserted onto whatever display later inherits its ID.
  @Test("Displays that went away are pruned")
  func prunesOfflineDisplays() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.5, for: displayA)
    dimmer.setDimming(0.5, for: displayB)
    dimmer.pruneOffline(onlineDisplayIDs: [displayA])

    #expect(dimmer.dimmedDisplays == [displayA])

    // Only what happens from here on: `applied` also holds the two writes that
    // set this up.
    let beforeReassert = backend.applied.count
    dimmer.reassertAll()
    let afterPrune = backend.applied.dropFirst(beforeReassert)

    #expect(!afterPrune.isEmpty)
    #expect(afterPrune.allSatisfy { $0.display == displayA },
            "a pruned display must not be reasserted")
  }

  @Test("Quitting restores every display")
  func clearAllRestoresEverything() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.5, for: displayA)
    dimmer.setDimming(0.2, for: displayB)
    dimmer.clearAll()

    #expect(dimmer.dimmedDisplays.isEmpty)
    #expect(backend.restoreAllCount == 1)
    #expect(backend.restored.contains(displayA))
    #expect(backend.restored.contains(displayB))
  }

  /// The lockout guard, end to end: someone who drags to zero on their only
  /// display must still be able to see it to drag back.
  @Test("Dimming to zero still leaves a visible screen")
  func neverFullyBlack() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0, for: displayA)

    let peak = backend.peak(for: displayA) ?? 0
    #expect(peak >= GammaRamp.minimumFraction - 0.001)
    #expect(peak > 0)
  }

  @Test("Setting full brightness is a restore, not a ramp")
  func fullBrightnessRestores() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(1.0, for: displayA)

    #expect(backend.applied.isEmpty, "an identity ramp is a restore, not a write")
    #expect(backend.restored.contains(displayA))
    #expect(dimmer.dimmedDisplays.isEmpty)
  }
}
