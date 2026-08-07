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
          // Cards separate themselves; the dividers that used to sit between
          // these groups were doing a job the card edges now do better.
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
        .padding(.horizontal, Layout.tight)
        .padding(.top, Layout.tight)
        .entrance(index: volumeIndex)

      if !model.presetList.isEmpty {
        presetRow
          .entrance(index: presetIndex)
      }

      if let rule = model.activeRule {
        ruleCaption(rule)
          .transition(.blurReplace)
          .entrance(index: ruleIndex)
      }

      if model.needsAccessibilityPermission {
        permissionNotice
          .transition(.blurReplace.combined(with: .scale(0.96, anchor: .top)))
          .entrance(index: permissionIndex)
      }

      if let date = model.nextScheduledChange {
        scheduleCaption(date)
          .transition(.blurReplace)
          .entrance(index: scheduleIndex)
      }

      Divider().padding(.top, Layout.tight)
      footer
        .entrance(index: footerIndex)
    }
    .padding(Layout.normal)
    // Wider than before to absorb the card padding without the sliders getting
    // any shorter than they were.
    .frame(width: 320)
    .animation(motion.spatialDefault, value: model.needsAccessibilityPermission)
    // The motion tokens, the theme and `surfaceDepth` are set by
    // `MenuBarPanelWindow`, not here. A view cannot read an environment value
    // its own body installs — `@Environment(\.motion)` above was quietly seeing
    // the default and ignoring Reduce Motion — so the panel's environment is
    // set up one level out, the way `WindowCoordinator` does it for windows.
    // Opening the panel is a cheap, natural moment to notice a grant that
    // happened while the app was in the background.
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
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      previewed = preset
    }
  }

  // MARK: - Where the cascade has got to
  //
  // A chain rather than a base index with `+1`, `+2`, `+3` hung off it. Four of
  // the rows below the display cards are conditional, and fixed offsets meant
  // that a panel with no presets played the footer on beat three with nothing
  // on beats one and two — a stagger with holes in it, which reads as the
  // animation having stuck rather than as rows arriving. Each of these adds one
  // only if the row before it is actually there.

  private var volumeIndex: Int {
    model.displays.count + (model.canSyncBrightness ? 1 : 0)
  }

  private var presetIndex: Int { volumeIndex + 1 }

  private var ruleIndex: Int { presetIndex + (model.presetList.isEmpty ? 0 : 1) }

  private var permissionIndex: Int { ruleIndex + (model.activeRule == nil ? 0 : 1) }

  private var scheduleIndex: Int {
    permissionIndex + (model.needsAccessibilityPermission ? 1 : 0)
  }

  private var footerIndex: Int {
    scheduleIndex + (model.nextScheduledChange == nil ? 0 : 1)
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
  /// The preset applied last is filled rather than tinted.
  ///
  /// `lastAppliedPresetID` has been recorded since presets existed and was
  /// shown nowhere, so the row of buttons looked identical whether one had just
  /// been applied or none ever had. Filling is what `SoftButtonStyle`'s own
  /// documentation reserves for the one action a surface is about, and it costs
  /// no height at all — which is the whole reason it is a fill and not a tick,
  /// a label change or a row of its own.
  ///
  /// "Applied last", never "current". The value is explicitly not a claim that
  /// the displays are still in that state, and a word like "current" would
  /// quietly upgrade it into one.
  private var presetRow: some View {
    HStack(spacing: Layout.tight) {
      ForEach(model.presetList) { preset in
        let isActive = preset.id == model.lastAppliedPresetID
        Button {
          model.apply(preset)
        } label: {
          Label(preset.name, systemImage: preset.symbolName)
            .labelStyle(.titleAndIcon)
            .font(TypeScale.detail.weight(.medium))
        }
        .buttonStyle(SoftButtonStyle(accent: theme.tone, isProminent: isActive))
        .help(isActive
          ? "Applied last — the displays may have moved since"
          : "Apply \(preset.name)")
        .onHover { preview($0 ? preset : nil) }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, Layout.tight)
    .animation(motion.effectDefault, value: model.lastAppliedPresetID)
  }

  /// Which app rule is currently in force.
  ///
  /// A preset applying itself when an application comes to the front is the one
  /// thing in this app that changes the screens with nobody touching anything,
  /// and until now it did so silently — the sliders moved and the panel offered
  /// no account of why. One line, and only when a rule is actually in force.
  private func ruleCaption(_ rule: AppModel.ActiveRule) -> some View {
    let preset = model.presetList.first { $0.id == rule.presetID }?.name ?? "a deleted preset"
    return HStack(spacing: Layout.tight) {
      Image(systemName: "app.badge")
        .font(.caption)
        .foregroundStyle(.secondary)
      // "Fallback" rather than an application's name when nothing matched:
      // the two are different facts, and the second one is the answer to
      // "why did nothing happen when I switched to this app".
      Text("\(rule.appName ?? "Fallback") → \(preset)")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Layout.tight)
  }

  /// What the schedule will do next.
  ///
  /// **Absolute, and computed once as the panel is built.** "21:00" is right
  /// for as long as the panel is open and needs nothing running to stay right;
  /// "in three hours" would be wrong within a minute and would need a tick to
  /// keep, which is the one thing this app will not spend.
  private func scheduleCaption(_ date: Date) -> some View {
    let time = date.formatted(date: .omitted, time: .shortened)
    let what = model.nextScheduledStop.map { " · \(model.summary(of: $0))" } ?? ""
    return HStack(spacing: Layout.tight) {
      Image(systemName: "clock")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Next change \(time)\(what)")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Layout.tight)
    .padding(.top, Layout.tight)
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
      caption

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
    // A display finishing its probe while the panel is open should read as the
    // caption going away, not as the card jumping under the pointer.
    .animation(motion.spatialDefault, value: display.brightnessBlock)
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

  /// Why this card is not doing what it looks like it should — when it is not.
  ///
  /// **The one thing the panel could never say.** A display that has not
  /// finished probing draws both its sliders greyed out, and a greyed-out
  /// control with no explanation is indistinguishable from a broken app.
  /// `!isReady` is the only thing that disables them, and `brightnessBlock`
  /// is exactly the sentence for it.
  ///
  /// Its own line under the header rather than a second line inside it,
  /// indented past the accent dot the way `permissionNotice` indents past its
  /// symbol. Folding it into the header would mean the "following the built-in"
  /// glyph, the warmth swatch and the readout all aligning against a two-line
  /// block, and none of them have a baseline to do it with.
  ///
  /// **Costs nothing in the ordinary case.** A healthy DDC monitor produces no
  /// block and therefore no row — which is the rule this whole surface is held
  /// to, because a line that is always there is paid for on every open, for
  /// every display, forever.
  ///
  /// What deliberately does *not* get a line here: a display with no speakers.
  /// It has no volume slider and says nothing about it, and that stays. The
  /// system output row is forty points below and is where that volume went, so
  /// a permanent "no volume here" under every such monitor would be spending
  /// height to say "look down". `SystemVolumeRow` already speaks for the case
  /// where there is genuinely nothing to drive, and the display's own page has
  /// the full explanation. Contrast is the same: the panel has never had a
  /// contrast slider and is not gaining an apology for one.
  @ViewBuilder
  private var caption: some View {
    if let block = display.brightnessBlock {
      Text(block.short)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Clears the accent dot, so the caption starts under the name.
        .padding(.leading, 14)
        .transition(.blurReplace)
    }
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
