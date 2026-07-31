import CoreGraphics
import Foundation
import Testing

@testable import PixelPilotCore

/// Records what would have been sent to the displays.
private final class RecordingBackend: GammaDimmer.Backend, @unchecked Sendable {
  /// The peak of each channel's ramp — what the screen would actually be at.
  struct Peaks: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    /// True when all three agree, which is what a pure luminance change looks
    /// like from here.
    var isNeutral: Bool { red == green && green == blue }
  }

  private let lock = NSLock()
  private var _applied: [(display: CGDirectDisplayID, peaks: Peaks)] = []
  private var _restored: [CGDirectDisplayID] = []
  private var _restoreAllCount = 0

  var applied: [(display: CGDirectDisplayID, peaks: Peaks)] { lock.withLock { _applied } }
  var restored: [CGDirectDisplayID] { lock.withLock { _restored } }
  var restoreAllCount: Int { lock.withLock { _restoreAllCount } }

  func peaks(for display: CGDirectDisplayID) -> Peaks? {
    lock.withLock { _applied.last { $0.display == display }?.peaks }
  }

  /// The luminance a caller would read off the screen, for the tests that only
  /// care about dimming.
  func peak(for display: CGDirectDisplayID) -> Double? {
    peaks(for: display)?.red
  }

  func applyRamps(
    red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue],
    to displayID: CGDirectDisplayID
  ) {
    lock.withLock {
      _applied.append((displayID, Peaks(
        red: Double(red.last ?? 0),
        green: Double(green.last ?? 0),
        blue: Double(blue.last ?? 0)
      )))
    }
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

  // MARK: - Colour

  private let warm = ColorTemperature.whitePoint(kelvin: 3000)

  /// The claim the whole design rests on: dimming and warming multiply, so
  /// neither has to know the other exists and the order makes no difference.
  @Test("Luminance and white point compose, in either order")
  func luminanceAndColourCompose() {
    let dimFirst = RecordingBackend()
    let a = GammaDimmer(backend: dimFirst)
    a.setDimming(0.6, for: displayA)
    a.setWhitePoint(warm, for: displayA)

    let warmFirst = RecordingBackend()
    let b = GammaDimmer(backend: warmFirst)
    b.setWhitePoint(warm, for: displayA)
    b.setDimming(0.6, for: displayA)

    #expect(dimFirst.peaks(for: displayA) == warmFirst.peaks(for: displayA))

    let peaks = dimFirst.peaks(for: displayA)
    #expect(abs((peaks?.red ?? 0) - 0.6 * warm.red) < 0.001)
    #expect(abs((peaks?.blue ?? 0) - 0.6 * warm.blue) < 0.001)
  }

  /// What keeps the existing behaviour honest: with no colour asked for, this
  /// must produce exactly what the single-ramp version did.
  @Test("A neutral white point is indistinguishable from plain dimming")
  func neutralMatchesPlainDimming() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0.5, for: displayA)

    let peaks = backend.peaks(for: displayA)
    #expect(peaks?.isNeutral == true)
    #expect(abs((peaks?.red ?? 0) - 0.5) < 0.001)
  }

  /// Warmth must not double as a brightness control. One channel stays at full,
  /// so a display that is only warmed is not also darkened.
  @Test("Warming alone does not dim")
  func warmingDoesNotDim() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setWhitePoint(warm, for: displayA)

    let peaks = backend.peaks(for: displayA)
    #expect(abs((peaks?.red ?? 0) - 1.0) < 0.001)
    #expect((peaks?.blue ?? 1) < 1.0)
    #expect(dimmer.dimmedDisplays.isEmpty, "a colour cast is not dimming")
    #expect(dimmer.tintedDisplays == [displayA])
  }

  /// Night Shift, a colour profile change and waking from sleep all reset the
  /// table. Restoring only half of what was held would leave the display in a
  /// state nobody chose.
  @Test("Reasserting restores both the dimming and the colour")
  func reassertRestoresBoth() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.7, for: displayA)
    dimmer.setWhitePoint(warm, for: displayA)
    let before = backend.peaks(for: displayA)

    dimmer.reassertAll()

    #expect(backend.peaks(for: displayA) == before)
  }

  @Test("Clearing the colour leaves the dimming alone")
  func clearingColourKeepsDimming() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.4, for: displayA)
    dimmer.setWhitePoint(warm, for: displayA)

    dimmer.setWhitePoint(.neutral, for: displayA)

    #expect(dimmer.dimmedDisplays == [displayA])
    #expect(dimmer.tintedDisplays.isEmpty)
    let peaks = backend.peaks(for: displayA)
    #expect(peaks?.isNeutral == true)
    #expect(abs((peaks?.red ?? 0) - 0.4) < 0.001)
  }

  @Test("Clearing the dimming leaves the colour alone")
  func clearingDimmingKeepsColour() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.4, for: displayA)
    dimmer.setWhitePoint(warm, for: displayA)

    dimmer.setDimming(1.0, for: displayA)

    #expect(dimmer.tintedDisplays == [displayA])
    let peaks = backend.peaks(for: displayA)
    #expect(abs((peaks?.red ?? 0) - warm.red) < 0.001)
    #expect(abs((peaks?.blue ?? 0) - warm.blue) < 0.001)
  }

  /// A monitor unplugged while warmed would otherwise keep its entry forever —
  /// and have it reasserted onto whatever display inherits its id.
  @Test("Pruning drops colour entries too")
  func pruningDropsColour() {
    let dimmer = GammaDimmer(backend: RecordingBackend())
    dimmer.setWhitePoint(warm, for: displayA)
    dimmer.setWhitePoint(warm, for: displayB)

    dimmer.pruneOffline(onlineDisplayIDs: [displayA])

    #expect(dimmer.tintedDisplays == [displayA])
  }

  @Test("Quitting clears colour as well as dimming")
  func clearAllClearsColour() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setWhitePoint(warm, for: displayA)
    dimmer.setDimming(0.5, for: displayB)

    dimmer.clearAll()

    #expect(dimmer.tintedDisplays.isEmpty)
    #expect(dimmer.dimmedDisplays.isEmpty)
    #expect(backend.restored.contains(displayA))
    #expect(backend.restored.contains(displayB))
  }
}
