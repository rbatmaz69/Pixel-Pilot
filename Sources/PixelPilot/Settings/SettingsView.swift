import PixelPilotCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let model: AppModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
      PresetSettings(model: model)
        .tabItem { Label("Presets", systemImage: "square.stack") }
      ScheduleSettings(model: model)
        .tabItem { Label("Schedule", systemImage: "sun.horizon") }
      AppRuleSettings(model: model)
        .tabItem { Label("Apps", systemImage: "app.badge") }
      ShortcutSettings(model: model)
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
    }
    // A fixed size rather than one per tab. The cards scroll, so a tab with
    // more in it no longer has to resize the window to show it — which was the
    // jumpiest thing about this window.
    .frame(width: 520, height: 580)
    .withMotionTokens()
  }
}

private struct GeneralSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  /// The store rather than `\.theme`: this card writes to it, and the resolved
  /// theme in the environment is derived from it one level further out.
  private var theme: ThemeStore { .shared }

  @State private var global = Preferences.shared.global
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchAtLoginError: String?
  @State private var isLearningKey = false
  /// The display awaiting a "yes, forget it".
  @State private var forgetting: DisplayKey?

  var body: some View {
    CardStack {
      themeCard.entrance(index: 0)
      keysCard.entrance(index: 1)
      permissionsCard.entrance(index: 2)
      detectionCard.entrance(index: 3)
      rememberedCard.entrance(index: 4)
      startupCard.entrance(index: 5)
    }
    .animation(motion.spatialDefault, value: model.needsRelaunchForPermissions)
    // Re-check on appearance as well as on activation: opening this window is
    // itself a moment the answer may have changed.
    .onAppear { model.refreshPermissions() }
    .sheet(isPresented: $isLearningKey) {
      KeyLearningSheet(model: model, isPresented: $isLearningKey)
        .withMotionTokens()
    }
  }

  /// The colour the whole application is drawn in.
  ///
  /// First card in the first tab, because it is the only setting here that
  /// changes something the moment it is touched — every open window repaints
  /// while this card is being looked at, which is the demonstration.
  private var themeCard: some View {
    PanelCard(title: "Colour theme", systemImage: "paintpalette") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Accent").font(TypeScale.rowTitle)
            Text("Sliders, switches and highlights")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: Layout.snug)
          AccentSwatchPicker(
            selection: Binding(
              get: { theme.toneIndex },
              // There is always an accent: no derived fallback to return to the
              // way a display has, so `allowsNone` is off and this can only
              // ever be handed an index.
              set: { value in if let value { theme.toneIndex = value } }
            ),
            allowsNone: false,
            accessibilityLabel: "Accent colour"
          )
        }

        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Background").font(TypeScale.rowTitle)
            Text(theme.backdropToneIndex == nil
              ? "Following the accent — pick one to set it apart"
              : "Windows, menus and cards")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: Layout.snug)
          // Allows none, and that is the difference from the row above: with
          // nothing chosen the field follows the accent, which is what the
          // whole interface looked like before these could differ. Tapping the
          // selected swatch again goes back to that.
          AccentSwatchPicker(
            selection: Binding(
              get: { theme.backdropToneIndex },
              set: { theme.backdropToneIndex = $0 }
            ),
            accessibilityLabel: "Background colour"
          )
        }
        .animation(motion.effectDefault, value: theme.backdropToneIndex)

        // Above Depth rather than below it, so the card reads as two questions
        // rather than four rows: which colour, then how it is drawn. The two
        // swatch rows answer the first and these two segmented pickers answer
        // the second.
        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Style").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: Binding(get: { theme.style }, set: { theme.style = $0 }),
            options: ThemeStyle.allCases.map { ($0, $0.displayName) }
          )
          Text(theme.style.summary)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
        .animation(motion.effectDefault, value: theme.style)

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Depth").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: Binding(get: { theme.mode }, set: { theme.mode = $0 }),
            options: ThemeMode.allCases.map { ($0, $0.displayName) }
          )
        }

        CardFooter("Glass keeps the translucent look the app shipped with, Vivid puts far "
          + "more of the colour into every surface, and Flat drops the material and the "
          + "gradients for colour and clear edges. Neither end of Depth is grey: light is a "
          + "pale wash of the background colour and dark is a deep one. Automatic follows "
          + "the system. Each display also keeps its own accent for telling monitors apart "
          + "— that one is in the Displays window.")
      }
    }
  }

  private var keysCard: some View {
    PanelCard(title: "Keyboard keys", systemImage: "keyboard") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Use the keyboard's brightness and volume keys", isOn: $global.mediaKeysEnabled)
          .onChange(of: global.mediaKeysEnabled) { _, _ in apply() }

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Per key press").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: $global.keyStep,
            options: [
              (1.0 / 8.0, "13%"),
              (1.0 / 16.0, "6%"),
              (1.0 / 24.0, "4%"),
              (1.0 / 32.0, "3%"),
            ]
          )
          .onChange(of: global.keyStep) { _, _ in apply() }
        }

        Toggle("Show the on-screen indicator", isOn: $global.showsOSD)
          .onChange(of: global.showsOSD) { _, _ in apply() }

        Toggle("Tap the trackpad at ends and quarters", isOn: $global.hapticsEnabled)
          .onChange(of: global.hapticsEnabled) { _, _ in apply() }

        CardFooter("While this is on the keys belong to Pixel Pilot — including on the "
          + "built-in panel, which means macOS no longer dims it as the room gets darker. "
          + "That trade is the point: one indicator and one step size on every screen. "
          + "Turning this off hands every key straight back. Hold Shift and Option while "
          + "pressing for finer steps. The trackpad taps only on hardware that can — macOS "
          + "decides that, and its own setting in Trackpad preferences wins over this one. "
          + "An external display can be set to follow the built-in panel in the Displays "
          + "window, which is how the light in the room reaches it.")
      }
    }
  }

  private var permissionsCard: some View {
    PanelCard(title: "Permissions", systemImage: "lock.shield") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        // Both statuses are always shown, granted or not. A warning that only
        // appears when something is missing leaves no way to tell "granted"
        // from "the app has not noticed yet".
        PermissionRow(
          title: "Accessibility",
          detail: "Needed to see the keys at all.",
          isGranted: model.accessibilityGranted,
          action: model.requestAccessibilityPermission
        )
        PermissionRow(
          title: "Input Monitoring",
          detail: "Needed for brightness keys on keyboards other than Apple's.",
          isGranted: model.inputMonitoringGranted,
          action: model.requestInputMonitoringPermission
        )

        if model.needsAccessibilityPermission || model.needsInputMonitoringPermission {
          CardFooter("If Pixel Pilot is already ticked in System Settings but still shows as "
            + "missing here, remove it with the “−” button and add it again. macOS keys "
            + "these grants to the app's signature, and entries from earlier builds go "
            + "stale.")
        }

        // Permission granted and the listener still not running is its own
        // state, and the only cure is a relaunch: macOS decides HID access when
        // the connection is opened, and a process that was refused stays
        // refused for its lifetime.
        if model.needsRelaunchForPermissions {
          Divider()
          StatusRow(
            symbol: "arrow.clockwise.circle.fill",
            tint: Status.info,
            title: "Restart to finish enabling",
            detail: "The permission is granted, but this running copy was already refused. "
              + "macOS only re-checks when the app starts."
          ) {
            Button("Restart") { model.relaunch() }
              .buttonStyle(.soft(Status.info))
              .font(TypeScale.detail.weight(.medium))
          }
          // This row appears the moment a grant is noticed, which is exactly
          // when the window is being looked at. Without a transition the whole
          // card jumps under the pointer.
          .transition(.blurReplace)
        }
      }
    }
  }

  private var detectionCard: some View {
    PanelCard(title: "Key detection", systemImage: "dot.radiowaves.left.and.right") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        // Which keyboards are being watched, and what the last one sent. These
        // two together separate "never matched" from "matched but silent",
        // which need completely different fixes.
        VStack(alignment: .leading, spacing: Layout.hair) {
          if model.watchedKeyboards.isEmpty {
            Text("Watching no keyboards.")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          } else {
            Text("Watching: \(model.watchedKeyboards.joined(separator: ", "))")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if let observed = model.lastObservedKey {
            Text(String(
              format: "Last key: usage 0x%02X from %@", observed.usage, observed.device
            ))
            .font(TypeScale.mono)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
          } else {
            Text("No media key seen yet — press one now.")
              .font(TypeScale.detail)
              .foregroundStyle(.tertiary)
          }
        }
        .animation(motion.effectDefault, value: model.lastObservedKey?.usage)

        learnedKeys

        Divider()

        VStack(alignment: .leading, spacing: Layout.hair) {
          Toggle("Also read keys at the hardware level", isOn: $global.hidMediaKeysEnabled)
            .onChange(of: global.hidMediaKeysEnabled) { _, _ in apply() }
          // Stated because it is the one thing in this app that is not free
          // when nothing is happening, and because the trade is real: some
          // keyboards need it and some do not.
          CardFooter("Needed for brightness keys on keyboards macOS does not recognise. "
            + "Costs about 0.3% of one CPU core while running; without it Pixel Pilot "
            + "uses none when idle.")
        }
      }
    }
  }

  private var startupCard: some View {
    PanelCard(title: "Startup", systemImage: "power") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        Toggle("Open at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let launchAtLoginError {
          Text(launchAtLoginError)
            .font(TypeScale.detail)
            .foregroundStyle(Status.bad)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: launchAtLoginError)
    }
  }

  /// Every panel the app has ever configured, and a way to let one go.
  ///
  /// Settings follow the panel rather than the port, which is what makes a
  /// monitor keep its configuration across a replug — and also what means a
  /// monitor that is sold, returned or reconfigured keeps its old settings
  /// forever with nothing to clear them.
  private var rememberedCard: some View {
    PanelCard(title: "Remembered displays", systemImage: "externaldrive.badge.checkmark") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        if model.knownDisplays.isEmpty {
          Text("Nothing remembered yet. A display is recorded the first time it is probed.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.knownDisplays, id: \.key) { entry in
            let connected = model.isConnected(entry.key)
            StatusRow(
              symbol: connected ? "display" : "display.trianglebadge.exclamationmark",
              tint: connected ? Status.ok : nil,
              title: entry.settings.lastKnownName.isEmpty
                ? "Unnamed display" : entry.settings.lastKnownName,
              detail: connected ? "Connected" : "Not connected"
            ) {
              Button {
                forgetting = entry.key
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.soft)
              .help("Forget this display")
            }
            .transition(.blurReplace)
          }
        }
      }
      .animation(motion.spatialDefault, value: model.knownDisplays.count)
    }
    .onAppear { model.refreshKnownDisplays() }
    .confirmationDialog(
      "Forget this display?",
      isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
      presenting: forgetting
    ) { key in
      Button("Forget", role: .destructive) {
        model.forgetDisplay(key)
        forgetting = nil
      }
      Button("Cancel", role: .cancel) { forgetting = nil }
    } message: { _ in
      // Naming what is actually lost, rather than asking "are you sure". The
      // expensive part is the capability cache: without it the panel is probed
      // again — six DDC round trips — the next time it appears.
      Text("Its accent colour, DDC timing and cached capabilities are discarded. The next "
        + "time it connects it will be probed again, which takes a few seconds.")
    }
  }

  /// Keys taught for keyboards the automatic detection does not cover.
  ///
  /// Automatic detection can only handle schemes that were anticipated. A
  /// keyboard using its own usage page cannot be recognised in advance — only
  /// observed — which is what this is for.
  @ViewBuilder
  private var learnedKeys: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      ForEach(model.keyBindingList) { binding in
        StatusRow(
          symbol: binding.action.symbolName,
          title: binding.action.displayName,
          detail: "\(binding.keyboardName) — \(binding.signature.description)"
        ) {
          Button {
            model.forgetLearnedKey(binding.signature)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.soft)
          .help("Forget this key")
        }
        // Teaching and forgetting a key both happen with this list on screen,
        // so both should be visible as changes rather than as jumps.
        .transition(.blurReplace)
      }

      HStack(spacing: Layout.tight) {
        Button("Teach a key…") { isLearningKey = true }
          .buttonStyle(.soft)
        Text("For keyboards whose keys are not recognised automatically.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .animation(motion.spatialDefault, value: model.keyBindingList.count)
  }

  private func apply() {
    Preferences.shared.updateGlobal { $0 = global }
    model.startMediaKeys()
  }

  /// `SMAppService` registration fails for an unsigned or ad-hoc signed build,
  /// so the error is surfaced rather than leaving a toggle that flips back on
  /// its own with no explanation.
  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      launchAtLoginError = "Could not change this: \(error.localizedDescription)"
    }
  }
}

private struct ShortcutSettings: View {
  let model: AppModel

  var body: some View {
    CardStack {
      PanelCard(title: "Global shortcuts", systemImage: "command") {
        VStack(alignment: .leading, spacing: Layout.snug) {
          ForEach(HotkeyCenter.Action.Builtin.allCases, id: \.self) { builtin in
            row(for: .builtin(builtin), label: builtin.displayName)
          }

          CardFooter("Shortcuts act on the display under the pointer. They work anywhere, "
            + "including over full-screen apps, and need no extra permission.")
        }
      }
      .entrance(index: 0)

      if !model.presetList.isEmpty {
        PanelCard(title: "Presets", systemImage: "square.stack") {
          VStack(alignment: .leading, spacing: Layout.snug) {
            ForEach(model.presetList) { preset in
              row(for: .preset(preset.id), label: preset.name, symbol: preset.symbolName)
            }
          }
        }
        .entrance(index: 1)
      }
    }
  }

  private func row(
    for action: HotkeyCenter.Action,
    label: String,
    symbol: String? = nil
  ) -> some View {
    StatusRow(symbol: symbol ?? "command", title: label) {
      ShortcutRecorder(shortcut: model.hotkeys.shortcut(for: action)) { shortcut in
        model.setHotkey(shortcut, for: action)
      }
    }
  }
}
