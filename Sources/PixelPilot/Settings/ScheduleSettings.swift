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
        Toggle("Change the displays on a schedule", isOn: Binding(
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
          + "between them. A stop either sets a brightness and a warmth on every display, or "
          + "applies a preset — and a preset is how it reaches one monitor and not the other. "
          + "Solar stops are optional and need a rough location: one decimal place, about "
          + "11 km.")
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
        title: "At \(DayArc.timeLabel(at: scrubbed)): \(summary(of: stop))",
        detail: "Set by \(DayArc.label(for: stop)). Looking changes nothing."
      )
      .transition(.blurReplace)
    }
  }

  /// A stop in one line: what it does, in the order it does it.
  private func summary(of stop: ScheduleStop) -> String {
    if let id = stop.presetID {
      // Named rather than unrolled into numbers. What a preset will do is a
      // question about the preset — the answer is on the Presets page, where
      // resting on one shows every display it touches.
      guard let preset = model.presetList.first(where: { $0.id == id }) else {
        return "a preset that no longer exists"
      }
      return "the “\(preset.name)” preset"
    }

    var parts: [String] = []
    if let brightness = stop.brightness {
      parts.append("\(Int((brightness * 100).rounded()))%")
    }
    if let kelvin = stop.kelvin {
      parts.append("\(Int(kelvin.rounded())) K")
    }
    // A stop is allowed to carry neither — `ScheduleAction.values` makes both
    // optional on purpose — and "nothing" is a better answer than an empty line.
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

  @ViewBuilder
  private func stopRow(_ stop: ScheduleStop) -> some View {
    if let index = schedule.stops.firstIndex(where: { $0.id == stop.id }) {
      VStack(alignment: .leading, spacing: Layout.snug) {
        HStack(spacing: Layout.tight) {
          Text(DayArc.label(for: stop))
            .font(TypeScale.rowTitle)
            .frame(width: 92, alignment: .leading)

          timeControl(index)

          Spacer(minLength: Layout.tight)

          Button {
            schedule.stops.removeAll { $0.id == stop.id }
            save()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.soft)
          .font(TypeScale.detail)
        }

        // Which of the two kinds of stop this is. A segmented picker rather
        // than a toggle, because neither of them is the off state — they are
        // two different things to do at the same moment.
        SegmentedMorphPicker(
          selection: kindBinding(index),
          options: [(StopKind.values, "Values"), (StopKind.preset, "Preset")]
        )

        switch schedule.stops[index].action {
        case .values:
          valueControls(index)
        case let .preset(id):
          presetControl(index, presetID: id)
        }
      }
      .padding(Layout.snug)
      .cardSurface(
        accent: selected == stop.id ? theme.tone : .secondary, radius: Layout.radiusControl
      )
      .contentShape(.rect)
      .onTapGesture { selected = stop.id }
      .animation(motion.spatialDefault, value: schedule.stops[index].action)
    }
  }

  /// Editing the time as a figure rather than only by dragging the arc.
  ///
  /// The drag is the rough gesture — it rounds to five minutes, and it has to,
  /// because a knob under a pointer cannot mean 21:47 on purpose. This is the
  /// exact one, and for a solar stop it is the *only* way to set the offset:
  /// dragging one works out its offset from a nominal half past six, which is a
  /// strange way to say "forty minutes after sunset".
  @ViewBuilder
  private func timeControl(_ index: Int) -> some View {
    switch schedule.stops[index].time {
    case .clock:
      DatePicker(
        "Time",
        selection: clockBinding(index),
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .datePickerStyle(.field)

    case .sunrise, .sunset:
      Stepper(value: offsetBinding(index), in: -180 ... 180, step: 5) {
        Text(offsetLabel(schedule.stops[index]))
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      }
      .fixedSize()
    }
  }

  /// Brightness and warmth, each of which can be left alone.
  ///
  /// Both switchable, because `ScheduleStop` makes both optional on purpose and
  /// the row had no way to say so — it drew a brightness slider always, and a
  /// stop that set no brightness read as "0 %" above a handle sitting at 70.
  @ViewBuilder
  private func valueControls(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Toggle("Set the brightness", isOn: brightnessEnabled(index))

      if let brightness = schedule.stops[index].brightness {
        LabeledReadout(title: "Brightness", value: brightness) {
          ExpressiveSlider(
            value: Binding(
              get: { schedule.stops[index].brightness ?? 0.7 },
              set: { setBrightness($0, at: index) }
            ),
            accent: theme.tone,
            icon: "sun.max.fill",
            onCommit: { _ in save() }
          )
        }
        .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
      }

      Toggle("Set the warmth", isOn: warmthEnabled(index))

      if let kelvin = schedule.stops[index].kelvin {
        warmthSlider(index, kelvin: kelvin)
          .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
      }
    }
    .animation(motion.spatialDefault, value: schedule.stops[index].brightness == nil)
    .animation(motion.spatialDefault, value: schedule.stops[index].kelvin == nil)
  }

  private func warmthSlider(_ index: Int, kelvin: Double) -> some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text("Warmth")
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        // 6500 K is where the app takes its table off the display altogether,
        // and a stop set there is doing something worth naming rather than
        // "6500 K" — the schedule's own way of saying "put the colour back".
        Text(abs(kelvin - ColorTemperature.neutralKelvin) < 1
          ? "Neutral" : "\(Int(kelvin.rounded())) K")
          .font(TypeScale.readout)
          .foregroundStyle(theme.tone)
          .contentTransition(.numericText(value: kelvin))
          .animation(motion.effectFast, value: kelvin)
      }

      ExpressiveSlider(
        value: Binding(
          get: { schedule.stops[index].kelvin ?? KelvinTrack.defaultKelvin },
          set: { setKelvin($0, at: index) }
        ),
        range: ColorTemperature.range,
        accent: theme.tone,
        trackStyle: AnyShapeStyle(KelvinTrack.gradient),
        detents: KelvinTrack.detents,
        onCommit: { _ in save() }
      )

      KelvinTrack.scaleLabels
    }
  }

  /// The preset a stop applies, and what to do when it is not there any more.
  ///
  /// The stop is marked rather than removed. A schedule stop was placed by
  /// hand, and quietly deleting it because a preset went is the app making a
  /// decision on somebody's behalf about a thing they built — the same argument
  /// the volume HUD makes: say what happened.
  @ViewBuilder
  private func presetControl(_ index: Int, presetID: UUID) -> some View {
    let preset = model.presetList.first { $0.id == presetID }

    VStack(alignment: .leading, spacing: Layout.tight) {
      ControlRow(title: "Apply") {
        MorphMenuPicker(title: preset?.name ?? "Choose a preset") {
          ForEach(model.presetList) { candidate in
            Button {
              schedule.stops[index].action = .preset(candidate.id)
              save()
            } label: {
              Label(candidate.name, systemImage: candidate.symbolName)
            }
          }
        }
      }

      if preset == nil {
        StatusRow(
          symbol: "exclamationmark.triangle.fill",
          tint: Status.warn,
          title: model.presetList.isEmpty ? "No presets yet" : "That preset is gone",
          detail: model.presetList.isEmpty
            ? "Capture one on the Presets page. Until then this stop does nothing."
            : "It was deleted after this stop was made. Nothing happens here until another "
              + "one is chosen."
        )
        .transition(.blurReplace)
      } else {
        CardFooter("A preset says something per display, which two numbers here cannot — "
          + "so this is how a stop reaches contrast, volume, or one monitor and not the "
          + "other.")
      }
    }
  }

  // MARK: - Bindings

  private enum StopKind: Hashable { case values, preset }

  /// Switching kinds keeps nothing from the other one, and that is deliberate:
  /// a preset and a pair of numbers are not two spellings of one thing, so
  /// carrying a stale brightness across would be inventing an intention.
  private func kindBinding(_ index: Int) -> Binding<StopKind> {
    Binding(
      get: { schedule.stops[index].presetID == nil ? .values : .preset },
      set: { kind in
        switch kind {
        case .values:
          guard schedule.stops[index].presetID != nil else { return }
          schedule.stops[index].action = .values(brightness: 0.7, kelvin: nil)
        case .preset:
          guard schedule.stops[index].presetID == nil else { return }
          // The first preset, so the row is a working stop the moment it is
          // switched. With no presets at all it points at an id nothing has,
          // which is not a trick: the stop really is a preset stop with no
          // preset behind it, and the row below says exactly that. Refusing the
          // switch instead would be a segment that does nothing when pressed.
          schedule.stops[index].action = .preset(model.presetList.first?.id ?? UUID())
        }
        save()
      }
    )
  }

  private func brightnessEnabled(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { schedule.stops[index].brightness != nil },
      set: { setBrightness($0 ? 0.7 : nil, at: index); save() }
    )
  }

  private func warmthEnabled(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { schedule.stops[index].kelvin != nil },
      set: { setKelvin($0 ? KelvinTrack.defaultKelvin : nil, at: index); save() }
    )
  }

  private func setBrightness(_ value: Double?, at index: Int) {
    schedule.stops[index].action = .values(
      brightness: value, kelvin: schedule.stops[index].kelvin
    )
  }

  private func setKelvin(_ value: Double?, at index: Int) {
    schedule.stops[index].action = .values(
      brightness: schedule.stops[index].brightness, kelvin: value
    )
  }

  /// The clock time as a `Date`, which is the only shape `DatePicker` takes.
  ///
  /// Built on today's date and read back as hour and minute, so the day it is
  /// hung on never leaves this binding — the stop stores a time of day, not an
  /// instant.
  private func clockBinding(_ index: Int) -> Binding<Date> {
    Binding(
      get: {
        guard case let .clock(hour, minute) = schedule.stops[index].time else { return Date() }
        return Calendar.current.date(
          bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) ?? Date()
      },
      set: { date in
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        schedule.stops[index].time = .clock(
          hour: parts.hour ?? 0, minute: parts.minute ?? 0
        )
        save()
      }
    )
  }

  private func offsetBinding(_ index: Int) -> Binding<Int> {
    Binding(
      get: {
        switch schedule.stops[index].time {
        case let .sunrise(offset), let .sunset(offset): offset
        case .clock: 0
        }
      },
      set: { offset in
        switch schedule.stops[index].time {
        case .sunrise: schedule.stops[index].time = .sunrise(offsetMinutes: offset)
        case .sunset: schedule.stops[index].time = .sunset(offsetMinutes: offset)
        case .clock: break
        }
        save()
      }
    )
  }

  private func offsetLabel(_ stop: ScheduleStop) -> String {
    switch stop.time {
    case .clock: ""
    case let .sunrise(offset), let .sunset(offset):
      offset == 0 ? "on the dot" : "\(offset > 0 ? "+" : "")\(offset) min"
    }
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
