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
    .frame(width: 460)
    .withMotionTokens()
  }
}

private struct GeneralSettings: View {
  let model: AppModel

  @State private var global = Preferences.shared.global
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchAtLoginError: String?

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

        if let observed = model.lastObservedKey {
          // Shows what the keyboard actually sends. On a keyboard that is not
          // working, this is the difference between diagnosing it and guessing.
          Text(String(
            format: "Last key seen: usage 0x%02X from %@", observed.usage, observed.device
          ))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        }

        Toggle("Show the on-screen indicator", isOn: $global.showsOSD)
          .onChange(of: global.showsOSD) { _, _ in apply() }
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
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    // Re-check on appearance as well as on activation: opening this window is
    // itself a moment the answer may have changed.
    .onAppear { model.refreshPermissions() }
  }

  private func permissionRow(
    _ title: String,
    detail: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(granted ? Color.green : .orange)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      if !granted {
        Button("Open Settings…", action: action)
          .buttonStyle(.link)
      }
    }
    .font(.callout)
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
    HStack {
      if let symbol {
        Image(systemName: symbol).foregroundStyle(.secondary)
      }
      Text(label)
      Spacer()
      ShortcutRecorder(shortcut: model.hotkeys.shortcut(for: action)) { shortcut in
        model.setHotkey(shortcut, for: action)
      }
    }
  }
}
