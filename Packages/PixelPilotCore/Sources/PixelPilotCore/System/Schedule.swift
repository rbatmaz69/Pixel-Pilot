import Foundation

/// When a stop happens.
public enum ScheduleTime: Codable, Sendable, Hashable {
  case clock(hour: Int, minute: Int)
  case sunrise(offsetMinutes: Int)
  case sunset(offsetMinutes: Int)

  public var isSolar: Bool {
    if case .clock = self { return false }
    return true
  }
}

/// What to do at that time.
///
/// Both values are optional so a stop can change only one of them. A schedule
/// that dims in the evening without touching colour is a perfectly ordinary
/// thing to want, and forcing a value for both would mean inventing one.
public struct ScheduleStop: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  public var time: ScheduleTime
  public var brightness: Double?
  public var kelvin: Double?

  public init(
    id: UUID = UUID(), time: ScheduleTime, brightness: Double? = nil, kelvin: Double? = nil
  ) {
    self.id = id
    self.time = time
    self.brightness = brightness
    self.kelvin = kelvin
  }
}

/// A day's worth of stops.
///
/// The design decision worth stating: **stops, not a ramp.** Four to six
/// wake-ups a day, with nothing at all scheduled in between. A schedule that
/// eased continuously from one value to the next would be a repeating timer
/// wearing a costume, on an app whose defining constraint is costing nothing
/// while idle.
public struct DaySchedule: Codable, Sendable, Equatable {
  public var isEnabled: Bool = false
  public var stops: [ScheduleStop] = []

  public init(isEnabled: Bool = false, stops: [ScheduleStop] = []) {
    self.isEnabled = isEnabled
    self.stops = stops
  }

  /// Sensible starting points, so an empty schedule is not the first thing
  /// anyone has to design themselves.
  public static var suggested: DaySchedule {
    DaySchedule(stops: [
      ScheduleStop(time: .sunrise(offsetMinutes: 0), brightness: 0.85, kelvin: 6500),
      ScheduleStop(time: .sunset(offsetMinutes: -30), brightness: 0.55, kelvin: 4500),
      ScheduleStop(time: .clock(hour: 22, minute: 0), brightness: 0.35, kelvin: 3200),
    ])
  }

  /// Every stop resolved to an instant on `day`, in order.
  ///
  /// Solar stops resolve to nothing when `solar` has no time for them — a
  /// sunrise stop above the Arctic Circle in December is not an error, there
  /// simply is no sunrise to hang it on, and it is skipped for that day.
  public func resolved(
    on day: Date, solar: Solar.Times?, calendar: Calendar = .current
  ) -> [(date: Date, stop: ScheduleStop)] {
    stops.compactMap { stop -> (date: Date, stop: ScheduleStop)? in
      guard let date = resolve(stop.time, on: day, solar: solar, calendar: calendar) else {
        return nil
      }
      return (date, stop)
    }
    .sorted { $0.date < $1.date }
  }

  /// The next stop strictly after `moment`, looking into tomorrow if today has
  /// nothing left.
  ///
  /// Returns nil rather than looping when there is nothing to find — an empty
  /// or all-polar schedule must produce "no next event", not a search that
  /// walks forward forever.
  public func nextTransition(
    after moment: Date,
    solar: (Date) -> Solar.Times?,
    calendar: Calendar = .current
  ) -> (date: Date, stop: ScheduleStop)? {
    guard isEnabled, !stops.isEmpty else { return nil }

    // Two days is enough: today's remaining stops, then tomorrow's. Looking
    // further would mean a schedule whose only stops are polar keeps searching,
    // and the honest answer there is that there is nothing to schedule.
    for dayOffset in 0 ... 1 {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: moment) else { continue }
      let candidates = resolved(on: day, solar: solar(day), calendar: calendar)
      if let next = candidates.first(where: { $0.date > moment }) {
        return next
      }
    }
    return nil
  }

  /// The stop that should already be in force at `moment` — the most recent one
  /// at or before it, looking back into yesterday if today has not started yet.
  ///
  /// This is what makes the schedule survive a launch or a wake in the middle
  /// of the day: without it, nothing would be applied until the next stop came
  /// round, which for an overnight setting could be twelve hours.
  public func currentStop(
    at moment: Date,
    solar: (Date) -> Solar.Times?,
    calendar: Calendar = .current
  ) -> ScheduleStop? {
    guard isEnabled, !stops.isEmpty else { return nil }

    for dayOffset in [0, -1] {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: moment) else { continue }
      let candidates = resolved(on: day, solar: solar(day), calendar: calendar)
      if let current = candidates.last(where: { $0.date <= moment }) {
        return current.stop
      }
    }
    return nil
  }

  private func resolve(
    _ time: ScheduleTime, on day: Date, solar: Solar.Times?, calendar: Calendar
  ) -> Date? {
    switch time {
    case let .clock(hour, minute):
      // Through `Calendar`, never by adding seconds to midnight: on the day a
      // time zone shifts, 22:00 is not 22 hours after midnight.
      return calendar.date(
        bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime
      )
    case let .sunrise(offset):
      return solar?.sunrise?.addingTimeInterval(Double(offset) * 60)
    case let .sunset(offset):
      return solar?.sunset?.addingTimeInterval(Double(offset) * 60)
    }
  }
}
