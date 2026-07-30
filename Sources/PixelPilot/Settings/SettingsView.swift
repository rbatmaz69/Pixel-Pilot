import PixelPilotCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let model: AppModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
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

        if model.needsAccessibilityPermission {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text("Accessibility permission is required.")
              .foregroundStyle(.secondary)
            Button("Open Settings…") { model.requestAccessibilityPermission() }
              .buttonStyle(.link)
          }
          .font(.callout)
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
        ForEach(HotkeyCenter.Action.allCases) { action in
          HStack {
            Text(action.displayName)
            Spacer()
            ShortcutRecorder(shortcut: model.hotkeys.shortcut(for: action)) { shortcut in
              model.setHotkey(shortcut, for: action)
            }
          }
        }
      } header: {
        Text("Global shortcuts")
      } footer: {
        Text("Shortcuts act on the display under the pointer. They work anywhere, "
          + "including over full-screen apps, and need no extra permission.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
