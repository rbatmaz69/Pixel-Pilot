import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Media key deduplication")
struct MediaKeyDeduplicatorTests {
  private let brightnessUp = 1
  private let brightnessDown = 2

  /// The case it exists for: one press reaching us through both the event tap
  /// and the HID layer would otherwise move brightness two steps.
  @Test("The same key arriving twice is handled once")
  func collapsesDuplicate() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let now = ContinuousClock.now

    let first = deduplicator.shouldHandle(key: brightnessUp, at: now)
    let second = deduplicator.shouldHandle(key: brightnessUp, at: now + .milliseconds(3))

    #expect(first)
    #expect(!second)
  }

  /// Holding a key repeats at roughly 30 ms, so the window must not swallow it.
  @Test("Key repeat still gets through")
  func allowsKeyRepeat() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let start = ContinuousClock.now

    let presses = [0, 30, 60].map {
      deduplicator.shouldHandle(key: brightnessUp, at: start + .milliseconds($0))
    }

    #expect(presses.allSatisfy { $0 })
  }

  /// Different keys must not suppress one another — pressing up then down in
  /// quick succession is a normal thing to do.
  @Test("Different keys are independent")
  func keysAreIndependent() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let now = ContinuousClock.now

    let up = deduplicator.shouldHandle(key: brightnessUp, at: now)
    let down = deduplicator.shouldHandle(key: brightnessDown, at: now + .milliseconds(2))

    #expect(up)
    #expect(down)
  }

  @Test("A press after the window is handled")
  func allowsAfterWindow() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let start = ContinuousClock.now

    let first = deduplicator.shouldHandle(key: brightnessUp, at: start)
    let later = deduplicator.shouldHandle(key: brightnessUp, at: start + .milliseconds(25))

    #expect(first)
    #expect(later)
  }

  /// A suppressed duplicate must not extend the window, or a steady stream of
  /// duplicates would block the key indefinitely.
  @Test("A suppressed duplicate does not push the window forward")
  func duplicateDoesNotExtendWindow() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let start = ContinuousClock.now

    let handled = deduplicator.shouldHandle(key: brightnessUp, at: start)
    let dropped = deduplicator.shouldHandle(key: brightnessUp, at: start + .milliseconds(10))
    // 25 ms after the *handled* press, not after the one that was dropped.
    let next = deduplicator.shouldHandle(key: brightnessUp, at: start + .milliseconds(25))

    #expect(handled)
    #expect(!dropped)
    #expect(next)
  }

  @Test("Resetting forgets what it saw")
  func resetClearsHistory() {
    var deduplicator = MediaKeyDeduplicator(window: .milliseconds(20))
    let now = ContinuousClock.now

    let first = deduplicator.shouldHandle(key: brightnessUp, at: now)
    deduplicator.reset()
    let afterReset = deduplicator.shouldHandle(key: brightnessUp, at: now + .milliseconds(1))

    #expect(first)
    #expect(afterReset)
  }
}
