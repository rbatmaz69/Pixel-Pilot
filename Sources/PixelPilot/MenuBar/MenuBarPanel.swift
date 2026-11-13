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

  let model: AppModel
  var onOpenSettings: () -> Void = {}

  /// The preset the pointer has been resting on long enough to mean it.
  @State private var previewed: Preset?
  @State private var previewTask: Task<Void, Never>?

  private var mood: AmbientDaylightMood { theme.resolvedAmbientMood }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      companionBanner

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
    .onAppear { model.refreshPermissions() }
    .onDisappear { previewTask?.cancel() }
  }

  /// Warm personal time-of-day studio greeting banner at the top of the popover.
  private var companionBanner: some View {
    HStack(spacing: Layout.snug) {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white.opacity(0.92),
                mood.orbColor,
                mood.orbColor.blended(with: .black, by: 0.18),
              ],
              center: UnitPoint(x: 0.34, y: 0.30),
              startRadius: 0,
              endRadius: 15
            )
          )
          .frame(width: 26, height: 26)
          .overlay {
            Circle()
              .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
          }
          .shadow(color: mood.orbColor.opacity(0.45), radius: 5)

        Image(systemName: mood.symbolName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(mood.greetingTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(mood.greetingSubtitle)
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      HStack(spacing: 5) {
        AccentDot(accent: theme.studioAccent, size: 6)
        Text(Preferences.shared.global.schedule.isEnabled ? "Tageshorizont" : "Studio")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        Capsule(style: .continuous)
          .fill(theme.recessedWell)
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(theme.groupBorder, lineWidth: 1)
      )
    }
    .padding(.horizontal, Layout.snug)
    .padding(.vertical, 8)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              theme.studioAccent.opacity(theme.isDark ? 0.14 : 0.10),
              theme.onGlassSurface,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .strokeBorder(theme.groupBorder, lineWidth: 1)
    }
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
        Text("No displays found")
          .font(TypeScale.cardTitle)
        Text(model.isDDCAvailable
          ? "Nothing is answering on the DDC bus yet."
          : "DDC/CI is unavailable on this system. Software dimming is still possible.")
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
        title: "Brightness keys need permission",
        detail: "Allow Pixel Pilot under Privacy & Security → Accessibility to use "
          + "the keyboard's brightness keys."
      )

      Button("Open Settings…") {
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
        Label("Settings", systemImage: "gearshape")
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
                .accessibilityLabel("An update is available")
            }
          }
      }
      .help(model.updater.hasUpdate
        ? "An update is available — displays, presets, schedule and keys"
        : "Displays, presets, schedule and keys")
      .animation(motion.effectDefault, value: model.updater.hasUpdate)

      Spacer()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Quit Pixel Pilot")
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

  private var previewEntry: PresetEntry? {
    preview?.entry(for: display.key)
  }

  /// A preset is being considered, and it says nothing about this display.
  private var isUnaffected: Bool { preview != nil && previewEntry == nil }

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
          .help(display.isMuted ? "Unmute" : "Mute")
        }
      }
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    // No ambient wash on this card, and that is a decision rather than an
    // omission — it used to carry one.
    //
    // The wash is two blurred blobs of the display's accent, and the larger one
    // sits 52 pt to the left of centre. On the tall column in the Displays
    // window that reads as depth behind a lot of content. On a 70 pt card it is
    // most of the card, so it stopped reading as light and started reading as a
    // stain under the brightness slider — a shadow nobody could account for,
    // which is worse than a flat surface.
    //
    // `cardSurface` still tints and rims the card in the display's colour, so
    // the card is no less that display's. It has simply stopped being lit from
    // one side.
    //
    // Worth noting what else went with it: `AmbientBackdrop` is the one thing
    // in this app that moves on its own, and this was the copy of it that ran
    // whenever the panel was open — which is the surface opened dozens of times
    // a day. A display's page in the settings window keeps its own.
    .cardSurface(accent: display.accent)
    // A preset that says nothing about this display steps back rather than
    // announcing itself. "Not mentioned" is the ordinary case — a preset for
    // the desk monitors is not a warning about the laptop — so it gets the
    // quietest signal there is, and an opacity rather than anything that moves.
    .opacity(isUnaffected ? 0.5 : 1)
    .animation(motion.effectDefault, value: isUnaffected)
  }

  private var header: some View {
    HStack(spacing: Layout.tight) {
      AccentDot(accent: display.accent, isReady: display.isReady)

      Text(display.name)
        .font(TypeScale.cardTitle)
        .lineLimit(1)

      // A slider that moves on its own is unsettling until you know why. This
      // is the whole explanation, and it costs one glyph.
      if display.followsBuiltinBrightness {
        Image(systemName: "a.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("Following the built-in display")
          .transition(.blurReplace)
      }

      warmthSwatch

      Spacer()

      EditableReadout(value: display.brightness, accent: display.accent) { value in
        display.setBrightness(value)
        display.commitBrightness()
      }
      .foregroundStyle(theme.ink(for: display.accent))
      .disabled(!display.isReady)

      // The live figure stays put and keeps telling the truth about the screen.
      // The arrow is the only thing making a claim about the future, which is
      // why it is a second label rather than a replacement for the first.
      if let target = previewEntry?.brightness {
        Text("→ \(Int((target * 100).rounded()))%")
          .font(TypeScale.readout)
          .foregroundStyle(.secondary)
          .transition(.blurReplace)
      }
    }
    .animation(motion.effectDefault, value: previewEntry)
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
        .help("Warmth off")
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
