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
/// The two ways out are closures rather than `openWindow` and `SettingsLink`.
/// Both of those are scene-graph facilities, and this view is hosted by AppKit
/// now. Injecting them also means the panel no longer knows what a window is,
/// which is the right amount for it to know.
struct MenuBarPanel: View {
  @Environment(\.motion) private var motion

  let model: AppModel
  var onOpenDisplays: () -> Void = {}
  var onOpenSettings: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      if model.displays.isEmpty {
        emptyState
      } else {
        ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
          // Cards separate themselves; the dividers that used to sit between
          // these groups were doing a job the card edges now do better.
          DisplayControlGroup(display: display)
            .entrance(index: index)
        }
      }

      SystemVolumeRow(audio: model.systemAudio)
        .padding(.horizontal, Layout.tight)
        .padding(.top, Layout.tight)
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

      Divider().padding(.top, Layout.tight)
      footer
        .entrance(index: trailingIndex + 3)
    }
    .padding(Layout.normal)
    // Wider than before to absorb the card padding without the sliders getting
    // any shorter than they were.
    .frame(width: 320)
    .animation(motion.spatialDefault, value: model.needsAccessibilityPermission)
    .withMotionTokens()
    // The one surface that declares this. The panel's own material comes from
    // the window it lives in, so its cards must not lay a second sheet of glass
    // over the first — that reads as a flat wash with none of the depth either
    // layer was drawing for.
    .environment(\.surfaceDepth, .onGlass)
    // Opening the panel is a cheap, natural moment to notice a grant that
    // happened while the app was in the background.
    .onAppear { model.refreshPermissions() }
  }

  /// Where the cascade has got to by the time the per-display cards are done.
  private var trailingIndex: Int { model.displays.count }

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
  private var presetRow: some View {
    HStack(spacing: Layout.tight) {
      ForEach(model.presetList) { preset in
        Button {
          model.apply(preset)
        } label: {
          Label(preset.name, systemImage: preset.symbolName)
            .labelStyle(.titleAndIcon)
            .font(TypeScale.detail.weight(.medium))
        }
        .buttonStyle(.soft)
        .help("Apply \(preset.name)")
      }
      Spacer(minLength: 0)
    }
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

  private var footer: some View {
    HStack(spacing: Layout.tight) {
      Button(action: onOpenDisplays) {
        Label("Displays", systemImage: "slider.horizontal.3")
          .labelStyle(.titleAndIcon)
      }

      Spacer()

      Button(action: onOpenSettings) {
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
    .buttonStyle(.soft)
    .font(.callout)
    .padding(.top, Layout.tight)
  }
}

/// The controls for one display, as a card in that display's own colour.
private struct DisplayControlGroup: View {
  @Environment(\.motion) private var motion
  @Environment(\.colorScheme) private var colorScheme

  @Bindable var display: DisplayViewModel

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
    // The wash sits above the card's own tint and below its contents, clipped
    // to the card so the blur cannot bleed onto its neighbours.
    .background {
      AmbientBackdrop(accent: display.accent)
        .clipShape(RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous))
    }
    .cardSurface(accent: display.accent)
  }

  private var header: some View {
    HStack(spacing: Layout.tight) {
      AccentDot(accent: display.accent, isReady: display.isReady)

      Text(display.name)
        .font(TypeScale.cardTitle)
        .lineLimit(1)

      Spacer()

      Text("\(Int((display.brightness * 100).rounded()))%")
        .font(TypeScale.readout)
        .foregroundStyle(display.accent.accentText(colorScheme))
        .contentTransition(.numericText(value: display.brightness))
        .animation(motion.effectFast, value: display.brightness)
    }
  }
}
