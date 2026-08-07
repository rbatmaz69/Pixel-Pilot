import AppKit
import CoreLocation
import PixelPilotCore

/// Runs the day schedule.
///
/// **One task, sleeping until the next stop.** Never a repeating tick, and
/// never a poll. Four to six wake-ups a day, and between them there is nothing
/// scheduled at all — which is the only way a schedule can exist in an app that
/// measures 0.0 % CPU while idle.
///
/// This makes obsolete the comments in `Preset.swift` and the preset settings
/// that said a schedule was a bad trade because it would need a timer and a
/// location permission. Neither turned out to be true: a single scheduled sleep
/// is not a timer, and the location is optional, asked for once, and rounded
/// until it is barely a location at all.
///
/// `@Observable` for the sake of `nextFire` and `nextStop`, which the menu bar
/// panel and the overview board both read. Observation is pull-based — nothing
/// is scheduled by the macro, and no notification is posted when nothing is
/// looking — so the one sleeping task above is still the whole of what this
/// costs while idle.
@MainActor
@Observable
final class ScheduleRunner {
  private let apply: (ScheduleStop) -> Void

  // The machinery is ignored by observation, and has to be: `deinit` cancels
  // the task, and a `@Observable` stored property becomes a computed one that a
  // nonisolated deinit cannot reach. Nothing looks at any of these anyway — the
  // two things a view wants are `nextFire` and `nextStop` below.
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []

  @ObservationIgnored private var schedule: DaySchedule = .init()
  @ObservationIgnored private var coordinate: (latitude: Double, longitude: Double)?

  /// When the next stop is due, for the settings UI to show.
  private(set) var nextFire: Date?

  /// And what it will do when it gets there.
  ///
  /// Kept beside the date rather than looked up again from the schedule at the
  /// point of display: the two are decided together in `reschedule`, and a
  /// second lookup against a schedule that has since been edited would name a
  /// stop that is not the one the sleeping task is waiting for.
  private(set) var nextStop: ScheduleStop?

  init(apply: @escaping (ScheduleStop) -> Void) {
    self.apply = apply
  }

  func start() {
    let center = NotificationCenter.default
    // The three things that move a deadline out from under a sleeping task.
    for name in [
      NSNotification.Name.NSSystemTimeZoneDidChange,
      NSNotification.Name.NSCalendarDayChanged,
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reschedule() }
      })
    }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reschedule(catchingUp: true) }
      }
    )
  }

  func stop() {
    task?.cancel()
    task = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    observers = []
  }

  func update(schedule: DaySchedule, coordinate: (latitude: Double, longitude: Double)?) {
    self.schedule = schedule
    self.coordinate = coordinate
    reschedule(catchingUp: true)
  }

  // MARK: - Scheduling

  /// - Parameter catchingUp: Also applies the stop that should already be in
  ///   force. Right at launch and after a wake, where the last stop may have
  ///   come and gone while nothing was running; wrong after simply firing one,
  ///   which would apply it twice.
  private func reschedule(catchingUp: Bool = false) {
    task?.cancel()
    task = nil
    nextFire = nil
    nextStop = nil

    guard schedule.isEnabled else { return }

    if catchingUp, let current = schedule.currentStop(at: Date(), solar: solarTimes) {
      apply(current)
    }

    guard let next = schedule.nextTransition(after: Date(), solar: solarTimes) else { return }
    nextFire = next.date
    nextStop = next.stop

    task = Task { [weak self] in
      let delay = next.date.timeIntervalSinceNow
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled else { return }
      guard let self else { return }

      // The wall clock is re-read rather than trusted. A sleep measures elapsed
      // time; daylight saving, a manually changed clock and a long suspend all
      // move the deadline without any time passing, or pass time without
      // reaching the deadline. Firing early would apply an evening setting at
      // lunchtime.
      if Date() < next.date {
        self.reschedule()
        return
      }

      self.apply(next.stop)
      self.reschedule()
    }
  }

  private func solarTimes(for day: Date) -> Solar.Times? {
    guard let coordinate else { return nil }
    return Solar.times(
      date: day, latitude: coordinate.latitude, longitude: coordinate.longitude
    )
  }

  deinit {
    task?.cancel()
  }
}
