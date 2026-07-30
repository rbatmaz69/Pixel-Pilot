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
      ShortcutSettings(model: model)
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
    }
    // Wider than before: the rows now carry their explanation underneath the
    // title, and at 460 nearly every one of them wrapped to three lines.
    .frame(width: 500)
    .withMotionTokens()
  }
}

private struct GeneralSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  @State private var global = Preferences.shared.global
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchAtLoginError: String?
  @State private var isLearningKey = false

  var body: some View {
    Form {
      Section {
        Toggle("Use the keyboard's brightness and volume keys", isOn: $global.mediaKeysEnabled)
          .onChange(of: global.mediaKeysEnabled) { _, _ in apply() }

        // Both statuses are always shown, granted or not. A warning that only
        // appears when something is missing leaves no way to tell "granted"
        // from "the app has not noticed yet".
        permissionRow(
          "Accessibility",
          detail: "Needed to see the keys at all.",
          granted: model.accessibilityGranted,
          action: model.requestAccessibilityPermission
        )
        permissionRow(
          "Input Monitoring",
          detail: "Needed for brightness keys on keyboards other than Apple's.",
          granted: model.inputMonitoringGranted,
          action: model.requestInputMonitoringPermission
        )

        if model.needsAccessibilityPermission || model.needsInputMonitoringPermission {
          Text("If Pixel Pilot is already ticked in System Settings but still shows as "
            + "missing here, remove it with the “−” button and add it again. macOS keys "
            + "these grants to the app's signature, and entries from earlier builds go "
            + "stale.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Permission granted and the listener still not running is its own
        // state, and the only cure is a relaunch: macOS decides HID access when
        // the connection is opened, and a process that was refused stays
        // refused for its lifetime.
        if model.needsRelaunchForPermissions {
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
          // form jumps under the pointer.
          .transition(.blurReplace)
        }

        // Which keyboards are being watched, and what the last one sent. These
        // two together separate "never matched" from "matched but silent",
        // which need completely different fixes.
        VStack(alignment: .leading, spacing: 2) {
          if model.watchedKeyboards.isEmpty {
            Text("Watching no keyboards.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Watching: \(model.watchedKeyboards.joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if let observed = model.lastObservedKey {
            Text(String(
              format: "Last key: usage 0x%02X from %@", observed.usage, observed.device
            ))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          } else {
            Text("No media key seen yet — press one now.")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }

        learnedKeys

        Toggle("Show the on-screen indicator", isOn: $global.showsOSD)
          .onChange(of: global.showsOSD) { _, _ in apply() }

        VStack(alignment: .leading, spacing: 2) {
          Toggle("Also read keys at the hardware level", isOn: $global.hidMediaKeysEnabled)
            .onChange(of: global.hidMediaKeysEnabled) { _, _ in apply() }
          // Stated because it is the one thing in this app that is not free
          // when nothing is happening, and because the trade is real: some
          // keyboards need it and some do not.
          Text("Needed for brightness keys on keyboards macOS does not recognise. "
            + "Costs about 0.3% of one CPU core while running; without it Pixel Pilot "
            + "uses none when idle.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Keys")
      } footer: {
        Text("Hold Shift and Option while pressing a key for finer steps.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Step size") {
        Picker("Per key press", selection: $global.keyStep) {
          Text("6% (16 steps)").tag(1.0 / 16.0)
          Text("4% (24 steps)").tag(1.0 / 24.0)
          Text("3% (32 steps)").tag(1.0 / 32.0)
          Text("13% (8 steps)").tag(1.0 / 8.0)
        }
        .onChange(of: global.keyStep) { _, _ in apply() }
      }

      Section("Startup") {
        Toggle("Open at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let launchAtLoginError {
          Text(launchAtLoginError)
            .font(TypeScale.detail)
            .foregroundStyle(Status.bad)
            .transition(.blurReplace)
        }
      }
    }
    .formStyle(.grouped)
    .animation(motion.spatialDefault, value: model.needsRelaunchForPermissions)
    // Re-check on appearance as well as on activation: opening this window is
    // itself a moment the answer may have changed.
    .onAppear { model.refreshPermissions() }
    .sheet(isPresented: $isLearningKey) {
      KeyLearningSheet(model: model, isPresented: $isLearningKey)
        .withMotionTokens()
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
      ForEach(model.keyBindings.bindings) { binding in
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
      }
    }
    .animation(motion.spatialDefault, value: model.keyBindings.bindings.count)
  }

  /// Both permission states, as one row that reacts when the answer changes.
  ///
  /// The glyph swap is the whole point of the animation here: coming back from
  /// System Settings having granted something, the confirmation should be
  /// unmissable rather than a redraw you have to go looking for.
  private func permissionRow(
    _ title: String,
    detail: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    StatusRow(
      symbol: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
      tint: granted ? Status.ok : Status.warn,
      title: title,
      detail: detail
    ) {
      if !granted {
        Button("Open Settings…", action: action)
          .buttonStyle(.soft(Status.warn))
          .font(TypeScale.detail.weight(.medium))
          .transition(.blurReplace)
      }
    }
    .animation(motion.spatialDefault, value: granted)
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
    Form {
      Section {
        ForEach(HotkeyCenter.Action.Builtin.allCases, id: \.self) { builtin in
          row(for: .builtin(builtin), label: builtin.displayName)
        }
      } header: {
        Text("Global shortcuts")
      } footer: {
        Text("Shortcuts act on the display under the pointer. They work anywhere, "
          + "including over full-screen apps, and need no extra permission.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if !model.presets.presets.isEmpty {
        Section("Presets") {
          ForEach(model.presets.presets) { preset in
            row(for: .preset(preset.id), label: preset.name, symbol: preset.symbolName)
          }
        }
      }
    }
    .formStyle(.grouped)
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
