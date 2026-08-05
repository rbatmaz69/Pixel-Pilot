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

  /// Writes and restores in the order they happened.
  ///
  /// The separate `applied` and `restored` lists cannot answer the question
  /// that matters once a restore is global: *which came last*. A veil written
  /// and then wiped by somebody else's restore looks identical, in those two
  /// lists, to a veil written after one.
  struct Event {
    var display: CGDirectDisplayID
    var isRestore: Bool
  }

  private let lock = NSLock()
  private var _events: [Event] = []
  private var _applied: [(display: CGDirectDisplayID, peaks: Peaks)] = []
  /// The *bottom* of each ramp, recorded alongside the top. A tone curve is the
  /// first thing here that moves the floor, and a peak alone cannot tell a
  /// lifted black from an untouched one.
  private var _floors: [(display: CGDirectDisplayID, peaks: Peaks)] = []
  private var _ramps: [(display: CGDirectDisplayID, red: [CGGammaValue])] = []
  private var _restored: [CGDirectDisplayID] = []
  private var _restoreAllCount = 0

  var applied: [(display: CGDirectDisplayID, peaks: Peaks)] { lock.withLock { _applied } }
  var events: [Event] { lock.withLock { _events } }
  var restored: [CGDirectDisplayID] { lock.withLock { _restored } }
  var restoreAllCount: Int { lock.withLock { _restoreAllCount } }

  func peaks(for display: CGDirectDisplayID) -> Peaks? {
    lock.withLock { _applied.last { $0.display == display }?.peaks }
  }

  func floors(for display: CGDirectDisplayID) -> Peaks? {
    lock.withLock { _floors.last { $0.display == display }?.peaks }
  }

  /// The whole red ramp of the most recent write, for the comparisons that have
  /// to be exact rather than within a tolerance.
  func redRamp(for display: CGDirectDisplayID) -> [CGGammaValue]? {
    lock.withLock { _ramps.last { $0.display == display }?.red }
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
      _floors.append((displayID, Peaks(
        red: Double(red.first ?? 0),
        green: Double(green.first ?? 0),
        blue: Double(blue.first ?? 0)
      )))
      _ramps.append((displayID, red))
      _events.append(Event(display: displayID, isRestore: false))
    }
  }

  func restore(_ displayID: CGDirectDisplayID) {
    lock.withLock {
      _restored.append(displayID)
      _events.append(Event(display: displayID, isRestore: true))
    }
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

  // MARK: - Finish

  /// The regression guard for the whole tone-curve change: with no finish
  /// asked for, `channels` has to produce byte for byte what it produced
  /// before the parameter existed.
  @Test("An identity tone curve changes nothing about the ramps")
  func identityToneMatchesPlainDimming() {
    let plain = GammaRamp.channels(luminance: 0.6, whitePoint: warm)
    let explicit = GammaRamp.channels(luminance: 0.6, whitePoint: warm, tone: .identity)

    #expect(plain.red == explicit.red)
    #expect(plain.green == explicit.green)
    #expect(plain.blue == explicit.blue)
  }

  @Test("A finish alone is a write, not a restore")
  func finishAloneWrites() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setTone(.paper, for: displayA)

    #expect(dimmer.finishedDisplays == [displayA])
    #expect(dimmer.dimmedDisplays.isEmpty, "a finish is not dimming")
    #expect(dimmer.tintedDisplays.isEmpty, "a finish is not a colour cast")
    #expect(!backend.applied.isEmpty, "a display holding a finish must not be handed back")
    #expect(backend.restored.isEmpty)
  }

  /// The visible half of the feature: black comes up off the floor and white
  /// comes down off the ceiling.
  @Test("A finish lifts the black and lowers the white")
  func finishReshapesTheRamp() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setTone(.matte, for: displayA)

    let floor = backend.floors(for: displayA)?.red ?? 0
    let peak = backend.peak(for: displayA) ?? 0
    #expect(abs(floor - ToneCurve.matte.blackLift) < 0.001)
    #expect(abs(peak - ToneCurve.matte.whiteCeiling) < 0.001)
    #expect(floor > 0)
    #expect(peak < 1)
  }

  @Test("The three named finishes get progressively flatter")
  func namedFinishesAreOrdered() {
    #expect(ToneCurve.paper.blackLift < ToneCurve.matte.blackLift)
    #expect(ToneCurve.matte.blackLift < ToneCurve.ink.blackLift)
    #expect(ToneCurve.paper.whiteCeiling > ToneCurve.matte.whiteCeiling)
    #expect(ToneCurve.matte.whiteCeiling > ToneCurve.ink.whiteCeiling)
  }

  /// The same claim already made for dimming and warmth, now with three terms:
  /// all of it multiplies, so no order of setting them can produce a different
  /// screen.
  @Test("Dimming, warmth and finish compose in any order")
  func allThreeCompose() {
    let one = RecordingBackend()
    let a = GammaDimmer(backend: one)
    a.setDimming(0.6, for: displayA)
    a.setWhitePoint(warm, for: displayA)
    a.setTone(.paper, for: displayA)

    let other = RecordingBackend()
    let b = GammaDimmer(backend: other)
    b.setTone(.paper, for: displayA)
    b.setWhitePoint(warm, for: displayA)
    b.setDimming(0.6, for: displayA)

    #expect(one.redRamp(for: displayA) == other.redRamp(for: displayA))
    #expect(one.peaks(for: displayA) == other.peaks(for: displayA))
    #expect(one.floors(for: displayA) == other.floors(for: displayA))
  }

  /// Dimming scales the lifted floor rather than leaving it where it was. A
  /// floor that stayed put would swamp the picture at low brightness.
  @Test("Dimming brings the lifted black down with it")
  func dimmingScalesTheLiftedBlack() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setTone(.matte, for: displayA)
    let undimmed = backend.floors(for: displayA)?.red ?? 0
    dimmer.setDimming(0.5, for: displayA)
    let dimmed = backend.floors(for: displayA)?.red ?? 0

    #expect(abs(dimmed - undimmed * 0.5) < 0.001)
  }

  @Test("Reasserting restores the finish along with everything else")
  func reassertRestoresFinish() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.7, for: displayA)
    dimmer.setWhitePoint(warm, for: displayA)
    dimmer.setTone(.ink, for: displayA)
    let before = backend.redRamp(for: displayA)

    dimmer.reassertAll()

    #expect(backend.redRamp(for: displayA) == before)
  }

  @Test("Setting the identity finish takes it off")
  func identityToneClearsFinish() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.4, for: displayA)
    dimmer.setTone(.paper, for: displayA)

    dimmer.setTone(.identity, for: displayA)

    #expect(dimmer.finishedDisplays.isEmpty)
    #expect(dimmer.dimmedDisplays == [displayA], "clearing the finish leaves the dimming alone")
    #expect(abs((backend.floors(for: displayA)?.red ?? 1) - 0) < 0.001)
  }

  @Test("Pruning and clearing drop finishes too")
  func pruningAndClearingDropFinishes() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setTone(.paper, for: displayA)
    dimmer.setTone(.paper, for: displayB)

    dimmer.pruneOffline(onlineDisplayIDs: [displayA])
    #expect(dimmer.finishedDisplays == [displayA])

    dimmer.clear(displayA)
    #expect(dimmer.finishedDisplays.isEmpty)
    #expect(backend.restored.contains(displayA))
  }

  @Test("Quitting clears finishes as well")
  func clearAllClearsFinishes() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setTone(.ink, for: displayA)

    dimmer.clearAll()

    #expect(dimmer.finishedDisplays.isEmpty)
    #expect(backend.restored.contains(displayA))
  }

  /// The lockout guard again, with the new control in play: no finish, at any
  /// setting, may take a screen darker than the floor dimming is allowed to.
  @Test("A finish cannot black out a display")
  func finishCannotBlackOut() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setTone(ToneCurve(blackLift: 99, whiteCeiling: -99, softness: 99), for: displayA)
    dimmer.setDimming(0, for: displayA)

    let peak = backend.peak(for: displayA) ?? 0
    #expect(peak >= GammaRamp.minimumFraction * ToneCurve.ceilingRange.lowerBound - 0.001)
    #expect(peak > 0)
  }

  // MARK: - Veil

  @Test("A veil of 1 changes nothing about the ramps")
  func fullVeilMatchesPlainDimming() {
    let plain = GammaRamp.channels(luminance: 0.6, whitePoint: warm, tone: .paper)
    let explicit = GammaRamp.channels(luminance: 0.6, whitePoint: warm, tone: .paper, veil: 1.0)

    #expect(plain.red == explicit.red)
    #expect(plain.green == explicit.green)
    #expect(plain.blue == explicit.blue)
  }

  /// The whole reason the veil is a separate dictionary. `BrightnessController`
  /// reads `dimming(for:)` back to answer what a gamma-dimmed display is set
  /// to; if the veil landed there, the brightness slider would move every time
  /// the user changed window and a preset would capture the veiled value.
  @Test("A veil is invisible to everything that asks what the display is set to")
  func veilDoesNotMoveTheBrightness() {
    let dimmer = GammaDimmer(backend: RecordingBackend())
    dimmer.setDimming(0.5, for: displayA)

    dimmer.setVeil(0.6, for: displayA)

    #expect(dimmer.dimming(for: displayA) == 0.5, "the veil is not dimming")
    #expect(dimmer.dimmedDisplays == [displayA])
    #expect(dimmer.veiledDisplays == [displayA])
  }

  @Test("A veil alone is a write, not a restore")
  func veilAloneWrites() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setVeil(0.65, for: displayA)

    #expect(dimmer.veiledDisplays == [displayA])
    #expect(abs((backend.peak(for: displayA) ?? 0) - 0.65) < 0.001)
    #expect(backend.restored.isEmpty)
  }

  @Test("Dimming, warmth, finish and veil compose in any order")
  func allFourCompose() {
    let one = RecordingBackend()
    let a = GammaDimmer(backend: one)
    a.setDimming(0.7, for: displayA)
    a.setWhitePoint(warm, for: displayA)
    a.setTone(.paper, for: displayA)
    a.setVeil(0.6, for: displayA)

    let other = RecordingBackend()
    let b = GammaDimmer(backend: other)
    b.setVeil(0.6, for: displayA)
    b.setTone(.paper, for: displayA)
    b.setDimming(0.7, for: displayA)
    b.setWhitePoint(warm, for: displayA)

    #expect(one.redRamp(for: displayA) == other.redRamp(for: displayA))
  }

  @Test("Lifting the veil leaves everything else alone")
  func liftingVeilKeepsTheRest() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.5, for: displayA)
    dimmer.setTone(.matte, for: displayA)
    dimmer.setVeil(0.6, for: displayA)

    dimmer.setVeil(1.0, for: displayA)

    #expect(dimmer.veiledDisplays.isEmpty)
    #expect(dimmer.dimmedDisplays == [displayA])
    #expect(dimmer.finishedDisplays == [displayA])
    #expect(abs((backend.peak(for: displayA) ?? 0) - 0.5 * ToneCurve.matte.whiteCeiling) < 0.001)
  }

  @Test("Reasserting restores the veil with everything else")
  func reassertRestoresVeil() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.7, for: displayA)
    dimmer.setVeil(0.5, for: displayA)
    let before = backend.redRamp(for: displayA)

    dimmer.reassertAll()

    #expect(backend.redRamp(for: displayA) == before)
  }

  @Test("Pruning and quitting drop veils too")
  func pruningAndClearingDropVeils() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setVeil(0.5, for: displayA)
    dimmer.setVeil(0.5, for: displayB)

    dimmer.pruneOffline(onlineDisplayIDs: [displayA])
    #expect(dimmer.veiledDisplays == [displayA])

    dimmer.clearAll()
    #expect(dimmer.veiledDisplays.isEmpty)
    #expect(backend.restored.contains(displayA))
  }

  /// The floor has to cover the two together. Flooring the luminance on its own
  /// and multiplying the veil in afterwards would put a display at minimum
  /// brightness below the level that floor exists to guarantee — the veil would
  /// have quietly reopened the lockout.
  @Test("A veil cannot take a dimmed display below the floor")
  func veilRespectsTheFloor() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setDimming(0, for: displayA)
    dimmer.setVeil(0.3, for: displayA)

    let peak = backend.peak(for: displayA) ?? 0
    #expect(peak >= GammaRamp.minimumFraction - 0.001)
    #expect(peak > 0)
  }

  // MARK: - Suspending

  @Test("A suspended display is handed back without being forgotten")
  func suspendHandsBack() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.5, for: displayA)
    dimmer.setTone(.paper, for: displayA)
    let before = backend.redRamp(for: displayA)

    dimmer.suspend(displayA)
    #expect(dimmer.isSuspended(displayA))
    #expect(backend.restored.contains(displayA))
    #expect(dimmer.dimmedDisplays == [displayA], "suspending is not forgetting")
    #expect(dimmer.finishedDisplays == [displayA])

    dimmer.resume(displayA)
    #expect(!dimmer.isSuspended(displayA))
    #expect(backend.redRamp(for: displayA) == before)
  }

  /// A wake or a colour-profile change does not stop happening because a test
  /// pattern is up, so reassertion has to keep handing the table back rather
  /// than writing over the pattern.
  @Test("Reasserting a suspended display keeps it suspended")
  func reassertRespectsSuspension() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.5, for: displayA)
    dimmer.suspend(displayA)
    let writesBefore = backend.applied.count

    dimmer.reassertAll()

    #expect(backend.applied.count == writesBefore, "nothing may be written to a suspended display")
  }

  /// The bug that made attention look broken, and was latent in warmth long
  /// before that.
  ///
  /// `CGDisplayRestoreColorSyncSettings` has no per-display form, so handing
  /// one display back hands *all* of them back. Clearing one display and
  /// setting another happens in one pass over a dictionary, whose order is
  /// unspecified — so when the clear landed second it erased what had just been
  /// written to the other screen, and the feature worked or did not depending
  /// on a hash seed that changes every launch.
  @Test("Clearing one display puts back what the others are holding")
  func clearingOneDisplayDoesNotWipeAnother() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    // The order that used to lose: write first, then clear the other one.
    dimmer.setVeil(0.3, for: displayA)
    dimmer.setVeil(1.0, for: displayB)

    // Whatever the global restore wiped must have been written again *after* it.
    let lastRestore = backend.events.lastIndex { $0.isRestore }
    let lastWriteToA = backend.events.lastIndex { $0.display == displayA && !$0.isRestore }
    #expect(lastRestore != nil)
    #expect(lastWriteToA != nil)
    #expect((lastWriteToA ?? 0) > (lastRestore ?? 0),
            "display A's veil must be re-written after the global restore wiped it")
    #expect(abs((backend.peak(for: displayA) ?? 0) - 0.3) < 0.001)
  }

  @Test("Warmth on one display survives another being cleared")
  func clearingOneDisplayDoesNotWipeWarmth() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)

    dimmer.setWhitePoint(warm, for: displayA)
    dimmer.setWhitePoint(.neutral, for: displayB)

    let lastRestore = backend.events.lastIndex { $0.isRestore }
    let lastWriteToA = backend.events.lastIndex { $0.display == displayA && !$0.isRestore }
    #expect((lastWriteToA ?? 0) > (lastRestore ?? 0))
  }

  /// A display showing the system's own profile on purpose must not be written
  /// back over by another display's restore.
  @Test("A suspended display is not resurrected by someone else's restore")
  func suspendedDisplaySurvivesAnotherRestore() {
    let backend = RecordingBackend()
    let dimmer = GammaDimmer(backend: backend)
    dimmer.setDimming(0.5, for: displayA)
    dimmer.suspend(displayA)

    let before = backend.events.count
    dimmer.setVeil(1.0, for: displayB)

    let after = backend.events.dropFirst(before)
    #expect(!after.contains { $0.display == displayA && !$0.isRestore },
            "nothing may be written to a suspended display")
  }

  @Test("Suspension does not survive the display going away")
  func pruningDropsSuspension() {
    let dimmer = GammaDimmer(backend: RecordingBackend())
    dimmer.setDimming(0.5, for: displayA)
    dimmer.suspend(displayA)

    dimmer.pruneOffline(onlineDisplayIDs: [displayB])

    #expect(!dimmer.isSuspended(displayA))
  }
}
