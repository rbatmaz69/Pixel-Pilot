import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Schedule")
struct ScheduleTests {
  private var berlin: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
  }

  private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    berlin.date(from: DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute
    ))!
  }

  private func noSolar(_ day: Date) -> Solar.Times? { nil }

  private func berlinSolar(_ day: Date) -> Solar.Times? {
    Solar.times(date: day, latitude: 52.52, longitude: 13.40, calendar: berlin)
  }

  private var clockSchedule: DaySchedule {
    DaySchedule(isEnabled: true, stops: [
      ScheduleStop(time: .clock(hour: 8, minute: 0), brightness: 0.9),
      ScheduleStop(time: .clock(hour: 22, minute: 0), brightness: 0.3),
    ])
  }

  @Test("The next stop later today is found")
  func nextToday() throws {
    let next = try #require(clockSchedule.nextTransition(
      after: moment(2024, 3, 10, 12), solar: noSolar, calendar: berlin
    ))
    #expect(next.date == moment(2024, 3, 10, 22))
  }

  /// The case a naive "find the first stop after now, today" gets wrong: after
  /// the last stop of the day there is nothing left until tomorrow.
  @Test("After the last stop of the day it rolls into tomorrow")
  func rollsOverMidnight() throws {
    let next = try #require(clockSchedule.nextTransition(
      after: moment(2024, 3, 10, 23), solar: noSolar, calendar: berlin
    ))
    #expect(next.date == moment(2024, 3, 11, 8))
  }

  /// Building a clock time by adding seconds to midnight is off by an hour on
  /// the two days a year a time zone shifts. Going through `Calendar` is not
  /// pedantry.
  @Test("A clock stop lands at the right wall time across a DST change")
  func survivesDaylightSaving() throws {
    // Central European Summer Time begins on 31 March 2024.
    let next = try #require(clockSchedule.nextTransition(
      after: moment(2024, 3, 31, 6), solar: noSolar, calendar: berlin
    ))
    let hour = berlin.component(.hour, from: next.date)
    #expect(hour == 8, "the 08:00 stop must still be at 08:00, not 07:00 or 09:00")
  }

  @Test("An empty schedule has no next transition, rather than searching forever")
  func emptyScheduleTerminates() {
    #expect(DaySchedule(isEnabled: true).nextTransition(
      after: moment(2024, 3, 10, 12), solar: noSolar, calendar: berlin
    ) == nil)
  }

  @Test("A disabled schedule fires nothing")
  func disabledFiresNothing() {
    var schedule = clockSchedule
    schedule.isEnabled = false
    #expect(schedule.nextTransition(
      after: moment(2024, 3, 10, 12), solar: noSolar, calendar: berlin
    ) == nil)
  }

  // MARK: - Solar stops

  @Test("A sunrise stop resolves against the day's solar times")
  func solarStopResolves() throws {
    let schedule = DaySchedule(isEnabled: true, stops: [
      ScheduleStop(time: .sunrise(offsetMinutes: 30), brightness: 0.9),
    ])
    let next = try #require(schedule.nextTransition(
      after: moment(2024, 6, 21, 0), solar: berlinSolar, calendar: berlin
    ))
    let hour = berlin.component(.hour, from: next.date)
    #expect(hour >= 4 && hour <= 6, "Berlin's midsummer sunrise plus half an hour")
  }

  /// A sunrise stop above the Arctic Circle in December is not an error. There
  /// is no sunrise to hang it on, and the schedule has to keep working.
  @Test("A solar stop with no solar time is skipped, not crashed on")
  func polarSolarStopIsSkipped() {
    let schedule = DaySchedule(isEnabled: true, stops: [
      ScheduleStop(time: .sunrise(offsetMinutes: 0), brightness: 0.9),
    ])
    #expect(schedule.nextTransition(
      after: moment(2024, 12, 21, 12), solar: noSolar, calendar: berlin
    ) == nil)
  }

  @Test("Clock stops still fire when the solar ones cannot")
  func clockStopsSurvivePolarNight() throws {
    let schedule = DaySchedule(isEnabled: true, stops: [
      ScheduleStop(time: .sunrise(offsetMinutes: 0), brightness: 0.9),
      ScheduleStop(time: .clock(hour: 22, minute: 0), brightness: 0.3),
    ])
    let next = try #require(schedule.nextTransition(
      after: moment(2024, 12, 21, 12), solar: noSolar, calendar: berlin
    ))
    #expect(berlin.component(.hour, from: next.date) == 22)
  }

  // MARK: - Catching up

  /// Without this, launching at noon would leave the display on whatever it was
  /// until the evening stop — twelve hours of a schedule that appears not to
  /// work.
  @Test("The stop already in force is found on launch")
  func currentStopIsFound() throws {
    let current = try #require(clockSchedule.currentStop(
      at: moment(2024, 3, 10, 12), solar: noSolar, calendar: berlin
    ))
    #expect(current.brightness == 0.9)
  }

  /// Before the first stop of the day, the one in force is yesterday's last.
  @Test("Early morning falls back to last night's stop")
  func currentStopLooksBackADay() throws {
    let current = try #require(clockSchedule.currentStop(
      at: moment(2024, 3, 10, 3), solar: noSolar, calendar: berlin
    ))
    #expect(current.brightness == 0.3)
  }

  @Test("Stops come back in time order however they were listed")
  func resolvedIsSorted() {
    let schedule = DaySchedule(isEnabled: true, stops: [
      ScheduleStop(time: .clock(hour: 22, minute: 0)),
      ScheduleStop(time: .clock(hour: 8, minute: 0)),
      ScheduleStop(time: .clock(hour: 14, minute: 0)),
    ])
    let hours = schedule.resolved(on: moment(2024, 3, 10, 0), solar: nil, calendar: berlin)
      .map { berlin.component(.hour, from: $0.date) }
    #expect(hours == [8, 14, 22])
  }
}
