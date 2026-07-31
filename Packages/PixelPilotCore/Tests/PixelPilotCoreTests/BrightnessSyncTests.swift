import Testing

@testable import PixelPilotCore

@Suite("Brightness sync")
struct BrightnessSyncTests {
  private let a = DisplayKey(rawValue: "aaa")
  private let b = DisplayKey(rawValue: "bbb")

  /// The bug this type exists to prevent, written down as a test because on
  /// hardware it only shows up after someone has already lost their setup.
  @Test("Driving the master to an end and back restores the original spread")
  func spreadSurvivesTheEnds() {
    let start: [DisplayKey: Double] = [a: 0.8, b: 0.6]
    let master = 0.8
    let offsets = BrightnessSync.offsets(levels: start, master: master)

    // All the way down: b pins at zero long before a does.
    let bottom = BrightnessSync.levels(master: 0, offsets: offsets)
    #expect(bottom[a] == 0)
    #expect(bottom[b] == 0)

    // And back. Naively re-deriving offsets from the clamped values would have
    // made both displays equal by now.
    let restored = BrightnessSync.levels(master: master, offsets: offsets)
    #expect(restored[a] == 0.8)
    #expect(abs((restored[b] ?? 0) - 0.6) < 1e-9)
  }

  @Test("The top end clamps too, and recovers the same way")
  func topEndRecovers() {
    let start: [DisplayKey: Double] = [a: 0.9, b: 0.5]
    let offsets = BrightnessSync.offsets(levels: start, master: 0.9)

    let top = BrightnessSync.levels(master: 1, offsets: offsets)
    #expect(top[a] == 1)
    #expect(abs((top[b] ?? 0) - 0.6) < 1e-9)

    let restored = BrightnessSync.levels(master: 0.9, offsets: offsets)
    #expect(abs((restored[b] ?? 0) - 0.5) < 1e-9)
  }

  @Test("A group at one level moves as one")
  func equalLevelsStayEqual() {
    let offsets = BrightnessSync.offsets(levels: [a: 0.5, b: 0.5], master: 0.5)
    let moved = BrightnessSync.levels(master: 0.2, offsets: offsets)
    #expect(moved[a] == 0.2)
    #expect(moved[b] == 0.2)
  }

  @Test("Levels never leave the range, whatever the master")
  func alwaysInRange() {
    let offsets = BrightnessSync.offsets(levels: [a: 1.0, b: 0.1], master: 0.55)
    for step in 0 ... 20 {
      let levels = BrightnessSync.levels(master: Double(step) / 20, offsets: offsets)
      for value in levels.values {
        #expect(value >= 0 && value <= 1)
      }
    }
  }

  /// Arming the group must not move anything by itself. Starting the master at
  /// one display's value would jump every other display the moment the switch
  /// is flipped.
  @Test("The suggested master is the average, so arming moves nothing far")
  func suggestedMasterIsTheAverage() {
    #expect(BrightnessSync.suggestedMaster(levels: [a: 0.8, b: 0.6]) == 0.7)
    #expect(BrightnessSync.suggestedMaster(levels: [a: 0.4]) == 0.4)
  }

  @Test("An empty group is a valid state")
  func emptyGroup() {
    #expect(BrightnessSync.suggestedMaster(levels: [:]) == 1)
    #expect(BrightnessSync.levels(master: 0.5, offsets: [:]).isEmpty)
  }
}
