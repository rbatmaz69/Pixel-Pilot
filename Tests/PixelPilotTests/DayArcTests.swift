import PixelPilotCore
import Testing

@testable import PixelPilot

/// Which stop the arc says is in force at a position on it.
///
/// Tested rather than eyeballed because the interesting case is invisible: the
/// hours before the day's first stop, where the answer has to come from
/// yesterday. That is exactly the stretch nobody scrubs while checking their
/// work, and exactly the stretch an evening setting is still governing.
@Suite("The day arc")
@MainActor
struct DayArcTests {
  private let morning = ScheduleStop(time: .clock(hour: 7, minute: 0), brightness: 0.9)
  private let evening = ScheduleStop(time: .clock(hour: 19, minute: 0), brightness: 0.5)
  private let night = ScheduleStop(time: .clock(hour: 22, minute: 0), brightness: 0.3)

  private var stops: [ScheduleStop] { [morning, evening, night] }

  @Test("The stop in force is the most recent one behind the pointer")
  func mostRecent() {
    // Midday: after the seven o'clock stop, before the evening one.
    #expect(DayArc.stop(at: 0.5, stops: stops)?.id == morning.id)
    // Half past eight in the evening.
    #expect(DayArc.stop(at: 20.5 / 24, stops: stops)?.id == evening.id)
    #expect(DayArc.stop(at: 23.0 / 24, stops: stops)?.id == night.id)
  }

  /// The reason the function wraps rather than returning nil.
  @Test("Before the first stop of the day, yesterday's last one still holds")
  func wrapsThroughMidnight() {
    #expect(DayArc.stop(at: 0, stops: stops)?.id == night.id)
    #expect(DayArc.stop(at: 3.0 / 24, stops: stops)?.id == night.id)
  }

  @Test("A stop is in force from the moment it is reached")
  func inclusiveAtTheStop() {
    #expect(DayArc.stop(at: 7.0 / 24, stops: stops)?.id == morning.id)
  }

  /// Stops arrive in whatever order they were added, and the arc sorts them
  /// itself. Relying on the caller to sort is how the early hours would start
  /// reporting whichever stop happened to be last in the array.
  @Test("The order stops were added in makes no difference")
  func orderIndependent() {
    let shuffled = [night, morning, evening]
    #expect(DayArc.stop(at: 0.5, stops: shuffled)?.id == morning.id)
    #expect(DayArc.stop(at: 0.02, stops: shuffled)?.id == night.id)
  }

  @Test("An empty schedule has nothing in force")
  func empty() {
    #expect(DayArc.stop(at: 0.5, stops: []) == nil)
  }

  @Test("A position on the arc reads as a clock time")
  func timeLabels() {
    #expect(DayArc.timeLabel(at: 0) == "00:00")
    #expect(DayArc.timeLabel(at: 0.5) == "12:00")
    // Midnight at the far end is midnight, not twenty-four o'clock.
    #expect(DayArc.timeLabel(at: 1) == "00:00")
  }
}
