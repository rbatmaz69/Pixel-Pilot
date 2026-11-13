import PixelPilotCore
import SwiftUI

/// The menu bar panel — the primary way the app is used.
///
/// This is only built while the panel is open, which is exactly what the energy
/// budget requires: closed, there is no view hierarchy, no observation and no
/// animation running. `MenuBarExtra` used to guarantee that; now
/// `MenuBarPanelWindow.close()` does, by dropping the hosting view rather than
/// ordering the window out.
///
/// That same property is what pays for the entrance. Because the hierarchy is
/// built fresh on every open, the staggered arrival plays every single time the
/// panel is used — and costs nothing at all in between.
///
/// The way out is a closure rather than `openWindow` or `SettingsLink`. Both of
/// those are scene-graph facilities, and this view is hosted by AppKit now.
/// Injecting it also means the panel no longer knows what a window is, which is
/// the right amount for it to know.
struct MenuBarPanel: View {
  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.fitPanelHeight) private var fitPanelHeight

  let model: AppModel
  var onOpenSettings: () -> Void = {}

  /// The preset the pointer has been resting on long enough to mean it.
  @State private var previewed: Preset?
  @State private var previewTask: Task<Void, Never>?

  private var mood: AmbientDaylightMood { theme.resolvedAmbientMood }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      if model.displays.isEmpty {
        emptyState
      } else {
        if model.canSyncBrightness {
          masterRow
            .entrance(index: 0)
        }

        ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
          DisplayControlGroup(display: display, preview: previewed)
            .accentWave(
              index: index,
              trigger: model.groupChangeTick,
              accent: display.accent
            )
            .entrance(index: index + (model.canSyncBrightness ? 1 : 0))
        }
      }

      SystemVolumeRow(audio: model.systemAudio)
        .padding(Layout.snug)
        .cardSurface(accent: theme.tone)
        .entrance(index: trailingIndex)

      if !model.presetList.isEmpty {
        presetRow
          .entrance(index: trailingIndex + 1)
      }

      if model.needsAccessibilityPermission {
        permissionNotice
          .transition(.blurReplace.combined(with: .scale(0.96, anchor: .top)))
          .entrance(index: trailingIndex + 2)
      }

      Divider().padding(.top, Layout.hair)
      footer
        .entrance(index: trailingIndex + 3)
    }
    .padding(Layout.normal)
    .frame(width: 332)
    .background(alignment: .top) {
      theme.ambientDaylightGradient(mood: mood)
        .frame(height: 110)
        .allowsHitTesting(false)
    }
    .animation(motion.spatialDefault, value: model.needsAccessibilityPermission)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, _ in
      fitPanelHeight()
    }
    .onAppear { model.refreshPermissions() }
    .onDisappear { previewTask?.cancel() }
  }

  /// Arms or cancels the preset preview.
  ///
  /// The wait is the whole reason this is a method rather than an assignment in
  /// `onHover`. A pointer crossing the preset row on its way to the footer
  /// passes over every button in it, and without the delay each one would flash
  /// a full set of ghosts on its way past — the panel would strobe.
  ///
  /// Cancelled and replaced rather than scheduled repeatedly: the same shape as
  /// `OSDController.dismissTask`, and for the same reason. Once the pointer
  /// settles there is nothing left running, and closing the panel takes the
  /// state with it.
  private func preview(_ preset: Preset?) {
    previewTask?.cancel()
    guard let preset else {
      previewed = nil
      return
    }
    previewTask = Task {
      try? await Task.sleep(for: .milliseconds(90))
      guard !Task.isCancelled else { return }
      previewed = preset
    }
  }

  /// Where the cascade has got to by the time the per-display cards are done.
  private var trailingIndex: Int {
    model.displays.count + (model.canSyncBrightness ? 1 : 0)
  }

  /// One slider for every display at once.
  ///
  /// Only shown with more than one display, because with one it would be a
  /// second copy of the slider directly below it. The differences between
  /// displays are captured when the switch is flipped and kept from then on —
  /// a monitor set 20 % dimmer than the other stays 20 % dimmer, including
  /// after a trip to the bottom of the range.
  private var masterRow: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(spacing: Layout.tight) {
        Image(systemName: "square.on.square.dashed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        // Shared with the HUD the all-displays key target puts up, so the two
        // cannot end up calling the same group two different things.
        Text(AppModel.everyDisplayName)
          .font(TypeScale.rowTitle)
        Spacer(minLength: 0)
        if model.isSyncingBrightness {
          EditableReadout(value: model.masterBrightness) { value in
            model.setMasterBrightness(value)
            model.commitMasterBrightness()
          }
          .foregroundStyle(.secondary)
        }
        Toggle("", isOn: Binding(
          get: { model.isSyncingBrightness },
          set: { model.setSyncingBrightness($0) }
        ))
        .labelsHidden()
        .toggleStyle(.morph)
      }

      if model.isSyncingBrightness {
        ExpressiveSlider(
          value: Binding(
            get: { model.masterBrightness },
            set: { model.setMasterBrightness($0) }
          ),
          accent: theme.tone,
          icon: "sun.max.fill",
          onCommit: { _ in model.commitMasterBrightness() }
        )
        .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
      }
    }
    .padding(Layout.snug)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: theme.tone)
    .animation(motion.spatialDefault, value: model.isSyncingBrightness)
  }

  /// Still the warning card rather than a full empty state.
  ///
  /// The panel is 320 pt of a menu bar popover, not a page — a centred
  /// illustration with a heading under it would push the volume row and the
  /// footer off the bottom. The radar goes beside the text instead, which is
  /// enough to say "looking" without spending the height on saying it.
  private var emptyState: some View {
    HStack(alignment: .top, spacing: Layout.snug) {
      SearchingRadar(accent: Status.warn, size: 34)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("Keine Displays gefunden")
          .font(TypeScale.cardTitle)
        Text(model.isDDCAvailable
          ? "Auf dem DDC-Bus antwortet derzeit kein Display."
          : "DDC/CI ist auf diesem System nicht verfügbar. Software-Dimmen bleibt aktiv.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: Status.warn)
    .entrance(index: 0)
  }

  /// Presets as a row of buttons rather than a list.
  ///
  /// They are the one thing here you press and forget, so they get the least
  /// vertical space — the sliders are what the panel is for.
  ///
  /// Resting on one previews it: every slider above grows a hollow handle where
  /// this preset would leave it. That is the one thing the panel could not say
  /// before — a preset was the only control here that did more than the surface
  /// showed, and the only way to find out what it did was to let it do it.
  ///
  /// **Nothing is written.** The preview reads `preset.entry(for:)` and draws;
  /// it never calls `setBrightness`, so hovering the row costs no DDC traffic
  /// at all. The master row deliberately gets no ghost: a preset holds a value
  /// per display and no master value, so any handle drawn there would be a
  /// number this app invented and then did not set.
  /// Atmospheric 2-column Mood Scene Cards grid with live Ghost-Preview bridge on hover.
  private var presetRow: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack {
        Text("LICHT-SZENEN")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.secondary)
          .tracking(0.5)
        Spacer()
        if let previewed {
          Text("Vorschau: \(previewed.name)")
            .font(TypeScale.editorialAccent)
            .foregroundStyle(theme.studioAccent)
            .transition(.opacity)
        }
      }

      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 7),
          GridItem(.flexible(), spacing: 7),
        ],
        spacing: 7
      ) {
        ForEach(model.presetList) { preset in
          MoodSceneCard(
            preset: preset,
            isPreviewed: previewed?.id == preset.id,
            action: { model.apply(preset) },
            onHoverChange: { hovering in preview(hovering ? preset : nil) }
          )
        }
      }
    }
    .padding(Layout.snug)
    .cardSurface(accent: theme.tone)
    .animation(motion.effectFast, value: previewed?.id)
  }

  /// Shown only when the brightness keys cannot work. Without it the keys would
  /// simply do nothing, with no indication of why or what to do about it.
  private var permissionNotice: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      StatusRow(
        symbol: "keyboard.badge.exclamationmark",
        tint: Status.warn,
        title: "Helligkeitstasten benötigen Berechtigung",
        detail: "Erlaube Pixel Pilot unter Datenschutz & Sicherheit → Bedienungshilfen."
      )

      Button("Einstellungen öffnen…") {
        model.requestAccessibilityPermission()
      }
      .buttonStyle(.soft(Status.warn))
      .font(TypeScale.detail.weight(.medium))
      .padding(.leading, 22)
    }
    .padding(Layout.snug)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: Status.warn)
    .padding(.top, Layout.tight)
  }

  /// One way in rather than two.
  ///
  /// There used to be a "Displays" button here as well, because the per-monitor
  /// configuration lived in a window of its own. It does not any more — it is a
  /// section of the settings window — and two buttons leading to one window is
  /// a choice with no difference behind it.
  private var footer: some View {
    HStack(spacing: Layout.tight) {
      Button(action: onOpenSettings) {
        Label("Einstellungen", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
          // A dot rather than a banner, a badge on the menu bar icon, or a row
          // that pushes the panel taller. An update is worth knowing about and
          // is never urgent — it can wait until the panel is open for some
          // other reason, which is what a dot on the way out says and what a
          // notch in the menu bar would not.
          .overlay(alignment: .topTrailing) {
            if model.updater.hasUpdate {
              AccentDot(accent: theme.tone, size: 6)
                .offset(x: 4, y: -2)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Ein Update ist verfügbar")
            }
          }
      }
      .help(model.updater.hasUpdate
        ? "Ein Update ist verfügbar – Displays, Szenen, Zeitplan & Tasten"
        : "Displays, Szenen, Zeitplan & Tasten")
      .animation(motion.effectDefault, value: model.updater.hasUpdate)

      Spacer()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Pixel Pilot beenden")
    }
    .buttonStyle(.soft)
    .font(.callout)
    .padding(.top, Layout.tight)
  }
}

/// The controls for one display, as a card in that display's own colour.
private struct DisplayControlGroup: View {
  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  @Bindable var display: DisplayViewModel
  /// The preset the pointer is resting on, if any. Read only, and read here
  /// rather than resolved by the panel, so a card answers "what would this do
  /// to *me*" without anything above it having to know.
  var preview: Preset?

  @State private var isStudioExpanded = false
  @State private var pendingAction: PendingDrawerAction?

  private enum PendingDrawerAction: Equatable {
    case input(UInt8)
    case power(PowerMode)

    var title: String {
      switch self {
      case let .input(value): "Zu \(InputLabel.full(for: value)) wechseln?"
      case let .power(mode): "\(PowerLabel.name(for: mode))?"
      }
    }
  }

  private static let neutralCutoff: Double = 6450

  private var previewEntry: PresetEntry? {
    preview?.entry(for: display.key)
  }

  /// A preset is being considered, and it says nothing about this display.
  private var isUnaffected: Bool { preview != nil && previewEntry == nil }

  private var sliderKelvin: Double {
    let raw = display.colorTemperatureKelvin ?? ColorTemperature.neutralKelvin
    return min(KelvinTrack.warmRange.upperBound, max(KelvinTrack.warmRange.lowerBound, raw))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      header

      ExpressiveSlider(
        value: Binding(
          get: { display.brightness },
          set: { display.setBrightness($0) }
        ),
        accent: display.accent,
        icon: "sun.max.fill",
        ghost: previewEntry?.brightness,
        onCommit: { _ in display.commitBrightness() }
      )
      .disabled(!display.isReady)

      // Only the display's own speakers belong here. System output volume is
      // global and lives at the foot of the panel.
      if display.hasDisplayAudio {
        HStack(spacing: Layout.tight) {
          ExpressiveSlider(
            value: Binding(
              get: { display.volume },
              set: { display.setVolume($0) }
            ),
            accent: display.accent,
            icon: "speaker.wave.2.fill"
          )

          Button {
            display.toggleMute()
          } label: {
            Image(systemName: display.isMuted ? "speaker.slash.fill" : "speaker.fill")
              .contentTransition(.symbolEffect(.replace))
              .symbolEffect(.bounce, value: display.isMuted)
          }
          .buttonStyle(.soft(display.accent))
          .help(display.isMuted ? "Ton ein" : "Stumm")
        }
      }

      if isStudioExpanded {
        studioDrawer
          .transition(.blurReplace.combined(with: .scale(0.98, anchor: .top)))
      }
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: display.accent)
    .opacity(isUnaffected ? 0.5 : 1)
    .animation(motion.effectDefault, value: isUnaffected)
    .animation(motion.spatialDefault, value: isStudioExpanded)
    .animation(motion.effectFast, value: pendingAction)
  }

  private var header: some View {
    HStack(spacing: Layout.tight) {
      AccentDot(accent: display.accent, isReady: display.isReady)

      Text(display.name)
        .font(TypeScale.cardTitle)
        .lineLimit(1)

      if display.followsBuiltinBrightness {
        Image(systemName: "a.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("Folgt dem integrierten Display")
          .transition(.blurReplace)
      }

      warmthSwatch

      Spacer(minLength: 4)

      studioDrawerTrigger

      EditableReadout(value: display.brightness, accent: display.accent) { value in
        display.setBrightness(value)
        display.commitBrightness()
      }
      .foregroundStyle(theme.ink(for: display.accent))
      .disabled(!display.isReady)

      if let target = previewEntry?.brightness {
        Text("→ \(Int((target * 100).rounded()))%")
          .font(TypeScale.readout)
          .foregroundStyle(.secondary)
          .transition(.blurReplace)
      }
    }
    .animation(motion.effectDefault, value: previewEntry)
  }

  private var studioDrawerTrigger: some View {
    Button {
      pendingAction = nil
      isStudioExpanded.toggle()
      Haptics.detent()
    } label: {
      HStack(spacing: 4) {
        if let kelvin = display.colorTemperatureKelvin {
          Text("\(Int(kelvin.rounded())) K")
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        } else {
          Image(systemName: "thermometer.sun")
            .font(.system(size: 10, weight: .semibold))
        }
        if let finishName = display.toneCurve?.namedFinish {
          Text("· \(finishName)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 8.5, weight: .bold))
          .rotationEffect(.degrees(isStudioExpanded ? 180 : 0))
      }
      .foregroundStyle(isStudioExpanded || display.colorTemperatureKelvin != nil || display.toneCurve != nil
        ? display.accent : .secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        Capsule(style: .continuous)
          .fill(isStudioExpanded ? display.accent.opacity(theme.isDark ? 0.22 : 0.14) : theme.recessedWell)
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(isStudioExpanded ? display.accent.opacity(0.45) : theme.groupBorder, lineWidth: 0.75)
      )
    }
    .buttonStyle(.plain)
    .help(isStudioExpanded ? "Studio-Regler einklappen" : "Farbwärme, Finish & Eingang einblenden")
    .accessibilityLabel("Studio-Regler für \(display.name)")
  }

  private var studioDrawer: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Divider()
        .overlay(theme.separator)

      // Farbwärme (Kelvin)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("FARBWÄRME")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
          Spacer()
          Text(display.colorTemperatureKelvin.map { "\(Int($0.rounded())) K" } ?? "6500 K · Neutral")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(display.colorTemperatureKelvin != nil ? display.accent : .secondary)
        }

        ExpressiveSlider(
          value: Binding(
            get: { sliderKelvin },
            set: { newValue in
              if newValue >= Self.neutralCutoff {
                if display.colorTemperatureKelvin != nil {
                  display.setColorTemperature(nil)
                }
              } else {
                display.setColorTemperature(newValue)
              }
            }
          ),
          range: KelvinTrack.warmRange,
          accent: display.accent,
          trackStyle: AnyShapeStyle(KelvinTrack.warmGradient),
          detents: KelvinTrack.warmDetents
        )

        HStack(spacing: 5) {
          ForEach(
            [
              (3500.0, "3500 K"),
              (4500.0, "4500 K"),
              (5500.0, "5500 K"),
              (6500.0, "Neutral"),
            ],
            id: \.0
          ) { preset in
            let isSelected = if preset.0 >= Self.neutralCutoff {
              display.colorTemperatureKelvin == nil
            } else if let active = display.colorTemperatureKelvin {
              abs(active - preset.0) < 60
            } else {
              false
            }
            Button(preset.1) {
              display.setColorTemperature(preset.0 >= Self.neutralCutoff ? nil : preset.0)
              Haptics.detent()
            }
            .buttonStyle(.soft(isSelected ? display.accent : .secondary))
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
          }
        }
      }

      // Papier- & Matt-Finish
      VStack(alignment: .leading, spacing: 6) {
        Text("FINISH")
          .font(.system(size: 9.5, weight: .bold))
          .tracking(0.5)
          .foregroundStyle(.secondary)

        SegmentedMorphPicker(
          selection: Binding(
            get: { display.toneCurve },
            set: { display.setToneCurve($0) }
          ),
          options: [
            (nil as ToneCurve?, "Aus"),
            (ToneCurve.paper, "Paper"),
            (ToneCurve.matte, "Matte"),
            (ToneCurve.ink, "Ink"),
          ],
          accent: display.accent
        )
        .controlSize(.small)
      }

      // Video-Eingänge & Ruhezustand für externe Monitore
      let standbyModes = display.availablePowerModes.filter { $0 != .on }
      if !display.isBuiltin && !display.availableInputs.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("EINGANG")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)

          let inputCount = display.availableInputs.count
          let columnCount = inputCount == 4 ? 2 : min(3, max(1, inputCount))
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columnCount),
            alignment: .leading,
            spacing: 5
          ) {
            ForEach(display.availableInputs, id: \.self) { value in
              let isCurrent = value == display.currentInput
              let isPending = pendingAction == .input(value)
              DrawerChip(
                title: InputLabel.short(for: value),
                systemImage: isCurrent ? "checkmark.circle.fill" : InputLabel.symbol(for: value),
                tint: display.accent,
                isSelected: isCurrent,
                isHighlighted: isPending
              ) {
                guard !isCurrent else { return }
                pendingAction = .input(value)
                Haptics.detent()
              }
              .help(isCurrent ? "\(InputLabel.full(for: value)) · aktiv" : "Zu \(InputLabel.full(for: value)) wechseln")
            }
          }
        }
      }

      if !display.isBuiltin && !standbyModes.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("BILDSCHIRM")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)

          HStack(spacing: 5) {
            ForEach(standbyModes, id: \.self) { mode in
              DrawerChip(
                title: PowerLabel.name(for: mode),
                systemImage: PowerLabel.symbol(for: mode),
                tint: Status.warn,
                isSelected: false,
                isHighlighted: pendingAction == .power(mode)
              ) {
                pendingAction = .power(mode)
                Haptics.detent()
              }
              .help(PowerLabel.help(for: mode))
            }
          }
        }
      }

      if !display.isBuiltin, let pendingAction {
        VStack(alignment: .leading, spacing: 6) {
          Text(pendingAction.title)
            .font(TypeScale.detail.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button("Abbrechen") {
              self.pendingAction = nil
            }
            .buttonStyle(.soft)
            .controlSize(.small)
            Button("Ausführen") {
              switch pendingAction {
              case let .input(value): display.switchInput(to: value)
              case let .power(mode): display.setPowerMode(mode)
              }
              self.pendingAction = nil
              Haptics.confirm()
            }
            .buttonStyle(.soft(Status.warn))
            .controlSize(.small)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
            .fill(Status.warn.opacity(theme.isDark ? 0.16 : 0.10))
        )
        .transition(.blurReplace)
      }
    }
    .padding(.top, 2)
  }

  /// What the previewed preset would do to this display's white point.
  ///
  /// Three states, because `PresetColor` has three and the middle one is the
  /// interesting one: a preset can say *take the warmth off*, and a preview
  /// that only ever showed a colour would make a "Day" preset look like it does
  /// less than it does.
  @ViewBuilder
  private var warmthSwatch: some View {
    switch previewEntry?.color {
    case .none:
      EmptyView()
    case .neutral:
      Image(systemName: "circle.slash")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Farbwärme aus")
        .transition(.blurReplace)
    case let .kelvin(kelvin):
      // The same function that drives the hardware, so the dot is the colour
      // the screen is about to be rather than an illustration of it.
      let point = ColorTemperature.whitePoint(kelvin: kelvin)
      Circle()
        .fill(Color(red: point.red, green: point.green, blue: point.blue))
        .frame(width: 9, height: 9)
        .overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5) }
        .help("\(Int(kelvin)) K")
        .transition(.blurReplace)
    }
  }
}

/// Atmospheric scene card inside the Menu Bar Popover's 2-column scene grid.
private struct MoodSceneCard: View {
  let preset: Preset
  let isPreviewed: Bool
  let action: () -> Void
  let onHoverChange: (Bool) -> Void

  @Environment(\.theme) private var theme
  @Environment(\.motion) private var motion
  @State private var isPressed = false

  private var averageBrightness: Double? {
    let values = preset.entries.values.compactMap(\.brightness)
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  private var representativeKelvin: Double? {
    for entry in preset.entries.values {
      if case let .kelvin(k) = entry.color { return k }
      if case .neutral = entry.color { return ColorTemperature.neutralKelvin }
    }
    return nil
  }

  private var moodTint: Color {
    if let kelvin = representativeKelvin {
      if kelvin <= 3900 {
        return Color(.sRGB, red: 0.878, green: 0.455, blue: 0.165)
      } else if kelvin <= 5000 {
        return Color(.sRGB, red: 0.918, green: 0.588, blue: 0.235)
      }
    }
    if let avg = averageBrightness, avg < 0.40 {
      return Color(.sRGB, red: 0.486, green: 0.380, blue: 0.690)
    }
    return theme.studioAccent
  }

  private var subtitleText: String {
    var parts: [String] = []
    if let avg = averageBrightness {
      parts.append("\(Int((avg * 100).rounded())) %")
    }
    if let kelvin = representativeKelvin {
      parts.append("\(Int((kelvin / 50).rounded() * 50)) K")
    }
    if parts.isEmpty {
      return "\(preset.entries.count) Display\(preset.entries.count == 1 ? "" : "s")"
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: preset.symbolName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(moodTint)
          .frame(width: 24, height: 24)
          .background(
            RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
              .fill(moodTint.opacity(theme.isDark ? 0.22 : 0.15))
          )
          .overlay(
            RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
              .strokeBorder(moodTint.opacity(0.35), lineWidth: 0.75)
          )

        VStack(alignment: .leading, spacing: 1) {
          Text(preset.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(subtitleText)
            .font(.system(size: 10, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                moodTint.opacity(isPreviewed ? (theme.isDark ? 0.24 : 0.18) : (theme.isDark ? 0.12 : 0.08)),
                theme.surfaceRaised.opacity(theme.isDark ? 0.65 : 0.85),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(
            isPreviewed ? moodTint.opacity(0.75) : theme.groupBorder,
            lineWidth: isPreviewed ? 1.25 : 1
          )
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Licht-Szene „\(preset.name)“ anwenden")
    .onHover(perform: onHoverChange)
    .animation(motion.effectFast, value: isPreviewed)
  }
}

/// One evenly sized, single-line choice inside the studio drawer — an icon and
/// a short label that never wraps, so a row of inputs reads at a glance.
private struct DrawerChip: View {
  let title: String
  let systemImage: String
  let tint: Color
  let isSelected: Bool
  var isHighlighted: Bool = false
  let action: () -> Void

  @Environment(\.theme) private var theme
  @Environment(\.motion) private var motion
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
        Text(title)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .foregroundStyle(isSelected || isHighlighted ? tint : Color.primary.opacity(0.82))
      .frame(maxWidth: .infinity, minHeight: 30)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
          .fill(
            isSelected || isHighlighted
              ? tint.opacity(theme.isDark ? 0.22 : 0.14)
              : (isHovered ? Color.primary.opacity(0.08) : theme.recessedWell)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
          .strokeBorder(
            isSelected || isHighlighted ? tint.opacity(0.55) : theme.groupBorder,
            lineWidth: 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(motion.effectFast, value: isHovered)
    .animation(motion.effectFast, value: isHighlighted)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Short, readable labels and icons for MCCS input codes.
enum InputLabel {
  static func short(for value: UInt8) -> String {
    switch value {
    case 0x0F: "DP 1"
    case 0x10: "DP 2"
    case 0x11: "HDMI 1"
    case 0x12: "HDMI 2"
    case 0x1B: "USB-C"
    default: InputSource.name(for: value)
    }
  }

  static func full(for value: UInt8) -> String {
    InputSource.name(for: value)
  }

  static func symbol(for value: UInt8) -> String {
    switch value {
    case 0x1B: "cable.connector"
    case 0x0F, 0x10: "rectangle.connected.to.line.below"
    case 0x11, 0x12: "tv"
    default: "cable.connector.horizontal"
    }
  }
}

/// German labels for DDC power modes.
enum PowerLabel {
  static func name(for mode: PowerMode) -> String {
    switch mode {
    case .on: "Einschalten"
    case .standby: "Standby"
    case .suspend: "Ruhezustand"
    case .off: "Bildschirm aus"
    case .powerOff: "Ausschalten"
    }
  }

  static func symbol(for mode: PowerMode) -> String {
    switch mode {
    case .on: "power"
    case .standby, .suspend: "moon.zzz"
    case .off: "moon.zzz"
    case .powerOff: "power"
    }
  }

  static func help(for mode: PowerMode) -> String {
    switch mode {
    case .powerOff:
      "Schaltet den Monitor komplett aus – einschalten nur am Gerät selbst"
    case .off:
      "Bildschirm schlafen legen – wacht bei Signal wieder auf"
    default:
      "Monitor in den \(name(for: mode)) versetzen"
    }
  }
}
