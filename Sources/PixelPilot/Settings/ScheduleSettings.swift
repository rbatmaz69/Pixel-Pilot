import CoreLocation
import PixelPilotCore
import SwiftUI

/// The day schedule.
struct ScheduleSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  @State private var schedule = Preferences.shared.global.schedule
  @State private var selected: UUID?
  /// Where on the arc the pointer is, while it is on the arc.
  @State private var scrubbed: Double?
  @State private var locator = OneShotLocator()
  @State private var manualLatitude = ""
  @State private var manualLongitude = ""

  private var usesSolar: Bool { schedule.stops.contains { $0.time.isSolar } }
  private var hasCoordinate: Bool { Preferences.shared.global.latitude != nil }

  var body: some View {
    CardStack {
      arcCard.entrance(index: 0)
      if schedule.isEnabled {
        stopsCard.entrance(index: 1)
        if usesSolar {
          locationCard.entrance(index: 2)
        }
      }
    }
    .animation(motion.spatialDefault, value: schedule.isEnabled)
    .animation(motion.spatialDefault, value: usesSolar)
  }

  // MARK: - The arc

  private var arcCard: some View {
    PanelCard(title: "Through the day", systemImage: "sun.horizon") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Change brightness and warmth on a schedule", isOn: Binding(
          get: { schedule.isEnabled },
          set: { enabled in
            if enabled, schedule.stops.isEmpty { schedule = .suggested }
            schedule.isEnabled = enabled
            save()
          }
        ))

        if schedule.isEnabled {
          DayArc(
            stops: schedule.stops,
            nowFraction: Self.nowFraction,
            selected: selected,
            onSelect: { selected = $0 },
            onMove: move,
            onScrub: { scrubbed = $0 }
          )
          .transition(.blurReplace)

          HStack {
            Text("Midnight").font(TypeScale.detail).foregroundStyle(.secondary)
            Spacer()
            Text("Noon").font(TypeScale.detail).foregroundStyle(.secondary)
            Spacer()
            Text("Midnight").font(TypeScale.detail).foregroundStyle(.secondary)
          }

          scrubReadout

          if let next = model.nextScheduledChange {
            StatusRow(
              symbol: "clock",
              title: "Next change \(Self.relative(next))",
              detail: "Nothing runs in between — one wake-up is scheduled, and that is all."
            )
            .transition(.blurReplace)
          }
        }

        // Rewriting a claim this app used to make. The preset settings said a
        // schedule was a bad trade because it needed a timer and a location;
        // neither turned out to be true, and leaving the old reasoning in place
        // next to the feature that disproves it would be worse than either.
        CardFooter("Stops, not a slow fade: a handful of moments a day with nothing scheduled "
          + "between them. Solar stops are optional and need a rough location — one decimal "
          + "place, about 11 km.")
      }
    }
  }

  /// What the screens would be doing at the moment the pointer is over.
  ///
  /// A schedule is a list of times, and reading a list is how you find out what
  /// it says at nine in the evening — which nobody does, so a stop that is
  /// wrong stays wrong until an evening goes badly. Pointing at the picture
  /// answers it instead.
  ///
  /// Kept to one row, in the space the card already had. This is a caption on
  /// the arc, not a second view of the schedule.
  @ViewBuilder
  private var scrubReadout: some View {
    if let scrubbed, let stop = DayArc.stop(at: scrubbed, stops: schedule.stops) {
      StatusRow(
        symbol: "eye",
        tint: theme.tone,
        title: "At \(DayArc.timeLabel(at: scrubbed)): \(Self.summary(of: stop))",
        detail: "Set by \(DayArc.label(for: stop)). Looking changes nothing."
      )
      .transition(.blurReplace)
    }
  }

  /// A stop in one line: what it does, in the order it does it.
  private static func summary(of stop: ScheduleStop) -> String {
    var parts: [String] = []
    if let brightness = stop.brightness {
      parts.append("\(Int((brightness * 100).rounded()))%")
    }
    if let kelvin = stop.kelvin {
      parts.append("\(Int(kelvin.rounded())) K")
    }
    // A stop is allowed to carry neither — `ScheduleStop` makes both optional
    // on purpose — and "nothing" is a better answer than an empty line.
    return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
  }

  // MARK: - Stops

  private var stopsCard: some View {
    PanelCard(title: "Stops", systemImage: "list.bullet") {
      VStack(alignment: .leading, spacing: Layout.snug) {
        ForEach(schedule.stops) { stop in
          stopRow(stop)
            .transition(.blurReplace)
        }

        HStack(spacing: Layout.tight) {
          Button("Add a time") {
            schedule.stops.append(
              ScheduleStop(time: .clock(hour: 12, minute: 0), brightness: 0.7)
            )
            save()
          }
          Button("Add sunrise") {
            schedule.stops.append(
              ScheduleStop(time: .sunrise(offsetMinutes: 0), brightness: 0.85, kelvin: 6500)
            )
            save()
          }
          Button("Add sunset") {
            schedule.stops.append(
              ScheduleStop(time: .sunset(offsetMinutes: 0), brightness: 0.5, kelvin: 4000)
            )
            save()
          }
        }
        .buttonStyle(.soft)
        .font(TypeScale.detail.weight(.medium))
      }
      .animation(motion.spatialDefault, value: schedule.stops.count)
    }
  }

  private func stopRow(_ stop: ScheduleStop) -> some View {
    let index = schedule.stops.firstIndex { $0.id == stop.id }

    return VStack(alignment: .leading, spacing: Layout.tight) {
      HStack {
        Text(DayArc.label(for: stop))
          .font(TypeScale.rowTitle)
          .frame(width: 120, alignment: .leading)
        Spacer()
        Button {
          schedule.stops.removeAll { $0.id == stop.id }
          save()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.soft)
        .font(TypeScale.detail)
      }

      if let index {
        LabeledReadout(
          title: "Brightness",
          value: schedule.stops[index].brightness ?? 0
        ) {
          ExpressiveSlider(
            value: Binding(
              get: { schedule.stops[index].brightness ?? 0.7 },
              set: { schedule.stops[index].brightness = $0 }
            ),
            accent: theme.tone,
            icon: "sun.max.fill",
            onCommit: { _ in save() }
          )
        }
      }
    }
    .padding(Layout.snug)
    .cardSurface(accent: selected == stop.id ? theme.tone : .secondary, radius: Layout.radiusControl)
    .contentShape(.rect)
    .onTapGesture { selected = stop.id }
  }

  // MARK: - Location

  private var locationCard: some View {
    PanelCard(title: "Where sunrise happens", systemImage: "location") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        if hasCoordinate {
          StatusRow(
            symbol: "checkmark.circle.fill",
            tint: Status.ok,
            title: "Location set",
            detail: coordinateDescription
          ) {
            Button("Clear") { model.setCoordinate(latitude: nil, longitude: nil) }
              .buttonStyle(.soft)
              .font(TypeScale.detail)
          }
        } else {
          StatusRow(
            symbol: "location.slash",
            tint: Status.warn,
            title: "No location yet",
            detail: "Sunrise and sunset stops do nothing until there is one. Clock stops "
              + "work regardless."
          )

          HStack(spacing: Layout.tight) {
            Button("Ask macOS once") { locator.requestOnce { model.setCoordinate(latitude: $0, longitude: $1) } }
              .buttonStyle(SoftButtonStyle(isProminent: true))
            if let error = locator.error {
              Text(error).font(TypeScale.detail).foregroundStyle(Status.bad)
            }
          }

          // The no-permission path, so the feature is never gated behind
          // granting something.
          HStack(spacing: Layout.tight) {
            TextField("Latitude", text: $manualLatitude)
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)
            TextField("Longitude", text: $manualLongitude)
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)
            Button("Use these") {
              guard let lat = Double(manualLatitude), let lon = Double(manualLongitude) else { return }
              model.setCoordinate(latitude: lat, longitude: lon)
            }
            .buttonStyle(.soft)
          }
          .font(TypeScale.detail)
        }

        CardFooter("Asked once, rounded to one decimal place, and kept. Sunrise does not need "
          + "to know which street you are on, so it is not stored.")
      }
      .animation(motion.spatialDefault, value: hasCoordinate)
    }
  }

  private var coordinateDescription: String {
    let global = Preferences.shared.global
    guard let latitude = global.latitude, let longitude = global.longitude else { return "" }
    return String(format: "%.1f, %.1f — accurate to about 11 km", latitude, longitude)
  }

  // MARK: - Editing

  private func move(_ id: UUID, to fraction: Double) {
    guard let index = schedule.stops.firstIndex(where: { $0.id == id }) else { return }
    let minutes = Int((fraction * 24 * 60).rounded() / 5) * 5

    switch schedule.stops[index].time {
    case .clock:
      schedule.stops[index].time = .clock(hour: min(23, minutes / 60), minute: minutes % 60)
    case .sunrise:
      // Solar stops keep their anchor and move their offset. Dragging one to
      // 09:00 means "three hours after sunrise", not "at nine", which is the
      // whole reason for choosing a solar stop in the first place.
      schedule.stops[index].time = .sunrise(offsetMinutes: minutes - 390)
    case .sunset:
      schedule.stops[index].time = .sunset(offsetMinutes: minutes - 1170)
    }
  }

  private func save() {
    model.updateSchedule { $0 = schedule }
  }

  private static var nowFraction: Double {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: Date())
    return (Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60) / 24
  }

  private static func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

/// Asks for the location exactly once, then lets go.
///
/// Not a location manager kept alive for the session: the answer is wanted one
/// time, is rounded to 11 km, and is then stored forever. Holding a delegate
/// open after that would be an ongoing cost for a value that never changes
/// enough to matter.
@MainActor
@Observable
final class OneShotLocator: NSObject, CLLocationManagerDelegate {
  private var manager: CLLocationManager?
  private var completion: ((Double, Double) -> Void)?
  private(set) var error: String?

  func requestOnce(_ completion: @escaping (Double, Double) -> Void) {
    error = nil
    self.completion = completion
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    self.manager = manager
    manager.requestWhenInUseAuthorization()
    manager.requestLocation()
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    guard let location = locations.last else { return }
    let coordinate = location.coordinate
    Task { @MainActor in
      completion?(coordinate.latitude, coordinate.longitude)
      finish()
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    let description = error.localizedDescription
    Task { @MainActor in
      self.error = description
      finish()
    }
  }

  private func finish() {
    manager?.delegate = nil
    manager = nil
    completion = nil
  }
}
