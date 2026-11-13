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
    PanelCard(title: "Tagesverlauf", systemImage: "sun.horizon") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Text("Sanfte Lichtpunkte entlang des natürlichen Tageshorizonts — ereignisgesteuert ohne Hintergrund-Timer.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)

        Toggle("Displays nach Tageszeit anpassen", isOn: Binding(
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
            Text("00:00 · Mitternacht").font(TypeScale.detail).foregroundStyle(.secondary)
            Spacer()
            Label("Aufgang", systemImage: "sunrise.fill")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
            Spacer()
            Text("12:00 · Mittag").font(TypeScale.detail.weight(.medium)).foregroundStyle(.primary.opacity(0.75))
            Spacer()
            Label("Untergang", systemImage: "sunset.fill")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
            Spacer()
            Text("24:00 · Mitternacht").font(TypeScale.detail).foregroundStyle(.secondary)
          }

          scrubReadout

          if let next = model.nextScheduledChange {
            StatusRow(
              symbol: "clock",
              title: "Nächster Wechsel \(Self.relative(next))",
              detail: "Nur ein geplanter Aufwachzeitpunkt — dazwischen 0 % CPU-Last."
            )
            .transition(.blurReplace)
          }
        }

        CardFooter("Jeder Lichtpunkt setzt Helligkeit & Wärme oder aktiviert ein Preset.")
      }
    }
  }

  @ViewBuilder
  private var scrubReadout: some View {
    if let scrubbed, let stop = DayArc.stop(at: scrubbed, stops: schedule.stops) {
      StatusRow(
        symbol: "eye",
        tint: theme.tone,
        title: "Um \(DayArc.timeLabel(at: scrubbed)): \(summary(of: stop))",
        detail: "Gesetzt durch \(DayArc.label(for: stop)). Vorschau ändert noch nichts."
      )
      .transition(.blurReplace)
    }
  }

  private func summary(of stop: ScheduleStop) -> String {
    if let id = stop.presetID {
      guard let preset = model.presetList.first(where: { $0.id == id }) else {
        return "fehlendes Preset"
      }
      return "Preset „\(preset.name)“"
    }

    var parts: [String] = []
    if let brightness = stop.brightness {
      parts.append("\(Int((brightness * 100).rounded()))%")
    }
    if let kelvin = stop.kelvin {
      parts.append("\(Int(kelvin.rounded())) K")
    }
    return parts.isEmpty ? "keine Änderung" : parts.joined(separator: ", ")
  }

  // MARK: - Stops

  private var stopsCard: some View {
    PanelCard(title: "Lichtpunkte", systemImage: "list.bullet") {
      VStack(alignment: .leading, spacing: Layout.snug) {
        ForEach(schedule.stops) { stop in
          stopRow(stop)
            .transition(.blurReplace)
        }

        HStack(spacing: Layout.tight) {
          Button("Zeitpunkt hinzufügen") {
            schedule.stops.append(
              ScheduleStop(time: .clock(hour: 12, minute: 0), brightness: 0.7)
            )
            save()
          }
          Button("Sonnenaufgang") {
            schedule.stops.append(
              ScheduleStop(time: .sunrise(offsetMinutes: 0), brightness: 0.85, kelvin: 6500)
            )
            save()
          }
          Button("Sonnenuntergang") {
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
          options: [(StopKind.values, "Werte"), (StopKind.preset, "Preset")]
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
        "Uhrzeit",
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

  @ViewBuilder
  private func valueControls(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Toggle("Helligkeit festlegen", isOn: brightnessEnabled(index))

      if let brightness = schedule.stops[index].brightness {
        LabeledReadout(title: "Helligkeit", value: brightness) {
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

      Toggle("Farbwärme festlegen", isOn: warmthEnabled(index))

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
        Text("Farbwärme")
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
      ControlRow(title: "Anwenden") {
        MorphMenuPicker(title: preset?.name ?? "Preset wählen") {
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
          title: model.presetList.isEmpty ? "Noch keine Presets" : "Preset nicht mehr vorhanden",
          detail: model.presetList.isEmpty
            ? "Erstelle zuerst ein Preset unter Licht-Szenen."
            : "Das verknüpfte Preset wurde gelöscht — wähle ein anderes."
        )
        .transition(.blurReplace)
      } else {
        CardFooter("Presets steuern auch Kontrast, Lautstärke und einzelne Monitore gezielt.")
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
      offset == 0 ? "genau dann" : "\(offset > 0 ? "+" : "")\(offset) Min."
    }
  }

  // MARK: - Location

  private var locationCard: some View {
    PanelCard(title: "Standort für Sonnenstand", systemImage: "location") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        if hasCoordinate {
          StatusRow(
            symbol: "checkmark.circle.fill",
            tint: Status.ok,
            title: "Standort gespeichert",
            detail: coordinateDescription
          ) {
            Button("Löschen") { model.setCoordinate(latitude: nil, longitude: nil) }
              .buttonStyle(.soft)
              .font(TypeScale.detail)
          }
        } else {
          StatusRow(
            symbol: "location.slash",
            tint: Status.warn,
            title: "Noch kein Standort",
            detail: "Wird nur für Sonnenauf- und Sonnenuntergangs-Punkte benötigt."
          )

          HStack(spacing: Layout.tight) {
            Button("macOS einmalig fragen") { locator.requestOnce { model.setCoordinate(latitude: $0, longitude: $1) } }
              .buttonStyle(SoftButtonStyle(isProminent: true))
            if let error = locator.error {
              Text(error).font(TypeScale.detail).foregroundStyle(Status.bad)
            }
          }

          HStack(spacing: Layout.tight) {
            TextField("Breitengrad", text: $manualLatitude)
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)
            TextField("Längengrad", text: $manualLongitude)
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)
            Button("Übernehmen") {
              guard let lat = Double(manualLatitude), let lon = Double(manualLongitude) else { return }
              model.setCoordinate(latitude: lat, longitude: lon)
            }
            .buttonStyle(.soft)
          }
          .font(TypeScale.detail)
        }

        CardFooter("Einmalig auf 11 km gerundet gespeichert — keine Standortverfolgung.")
      }
      .animation(motion.spatialDefault, value: hasCoordinate)
    }
  }

  private var coordinateDescription: String {
    let global = Preferences.shared.global
    guard let latitude = global.latitude, let longitude = global.longitude else { return "" }
    return String(format: "%.1f, %.1f — ca. 11 km Genauigkeit", latitude, longitude)
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
