import PixelPilotCore
import SwiftUI

/// The menu bar panel — the primary way the app is used.
///
/// SwiftUI only builds this while the panel is open, which is exactly what the
/// energy budget requires: closed, there is no view hierarchy, no observation
/// and no animation running.
struct MenuBarPanel: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.motion) private var motion

  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.displays.isEmpty {
        emptyState
      } else {
        ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
          if index > 0 {
            Divider().padding(.vertical, 10)
          }
          DisplayControlGroup(display: display)
        }
      }

      Divider().padding(.top, 12)
      SystemVolumeRow(audio: model.systemAudio)
        .padding(.top, 10)

      if !model.presets.presets.isEmpty {
        Divider().padding(.top, 12)
        presetRow
      }

      if model.needsAccessibilityPermission {
        Divider().padding(.top, 12)
        permissionNotice
      }

      Divider().padding(.top, 12)
      footer
    }
    .padding(14)
    .frame(width: 300)
    .withMotionTokens()
    // Opening the panel is a cheap, natural moment to notice a grant that
    // happened while the app was in the background.
    .onAppear { model.refreshPermissions() }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("No displays found", systemImage: "display.trianglebadge.exclamationmark")
        .font(.callout.weight(.medium))
      if !model.isDDCAvailable {
        Text("DDC/CI is unavailable on this system. Software dimming is still possible.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
  }

  /// Presets as a row of buttons rather than a list.
  ///
  /// They are the one thing here you press and forget, so they get the least
  /// vertical space — the sliders are what the panel is for.
  private var presetRow: some View {
    HStack(spacing: 6) {
      ForEach(model.presets.presets) { preset in
        Button {
          model.apply(preset)
        } label: {
          Label(preset.name, systemImage: preset.symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .buttonStyle(.accessoryBar)
        .help("Apply \(preset.name)")
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 10)
  }

  /// Shown only when the brightness keys cannot work. Without it the keys would
  /// simply do nothing, with no indication of why or what to do about it.
  private var permissionNotice: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Brightness keys need permission", systemImage: "keyboard.badge.exclamationmark")
        .font(.callout.weight(.medium))
      Text("Allow Pixel Pilot under Privacy & Security → Accessibility to use the keyboard's brightness keys.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Settings…") {
        model.requestAccessibilityPermission()
      }
      .buttonStyle(.borderless)
      .font(.caption.weight(.medium))
    }
    .padding(.top, 10)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        openWindow(id: WindowID.main)
      } label: {
        Label("Displays", systemImage: "slider.horizontal.3")
          .labelStyle(.titleAndIcon)
      }

      Spacer()

      SettingsLink {
        Image(systemName: "gearshape")
      }
      .help("Settings")

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Quit Pixel Pilot")
    }
    .buttonStyle(.accessoryBar)
    .font(.callout)
    .padding(.top, 10)
  }
}

/// The controls for one display.
private struct DisplayControlGroup: View {
  @Environment(\.motion) private var motion

  @Bindable var display: DisplayViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header

      ExpressiveSlider(
        value: Binding(
          get: { display.brightness },
          set: { display.setBrightness($0) }
        ),
        accent: display.accent,
        icon: "sun.max.fill",
        onCommit: { _ in display.commitBrightness() }
      )
      .disabled(!display.isReady)

      // Only the display's own speakers belong here. System output volume is
      // global and lives at the foot of the panel.
      if display.hasDisplayAudio {
        HStack(spacing: 8) {
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
          }
          .buttonStyle(.accessoryBar)
          .help(display.isMuted ? "Unmute" : "Mute")
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(display.accent)
        .frame(width: 7, height: 7)
        // A quiet cue that we are still talking to the panel. It settles once
        // and then stops — nothing here animates at rest.
        .opacity(display.isReady ? 1 : 0.3)
        .animation(motion.effectDefault, value: display.isReady)

      Text(display.name)
        .font(.callout.weight(.semibold))
        .lineLimit(1)

      Spacer()

      Text("\(Int((display.brightness * 100).rounded()))%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .animation(motion.effectFast, value: display.brightness)
    }
  }
}
