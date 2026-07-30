import PixelPilotCore
import SwiftUI

/// The full window: one display per sidebar row, with every control the panel
/// supports plus the diagnostics needed to work out why one of them is missing.
struct MainWindow: View {
  let model: AppModel

  @State private var selection: DisplayViewModel.ID?

  var body: some View {
    NavigationSplitView {
      List(model.displays, selection: $selection) { display in
        HStack(spacing: 8) {
          Circle()
            .fill(display.accent)
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 1) {
            Text(display.name).font(.body)
            Text(display.isBuiltin ? "Built-in" : display.routeDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .tag(display.id)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      if let display = model.displays.first(where: { $0.id == selection }) {
        DisplayDetail(display: display, log: model.log)
      } else {
        ContentUnavailableView(
          "Select a display",
          systemImage: "display",
          description: Text("Choose a display to see its controls and diagnostics.")
        )
      }
    }
    .onAppear {
      if selection == nil { selection = model.displays.first?.id }
    }
    .onChange(of: model.displays.map(\.id)) { _, ids in
      // A display was unplugged or replaced; do not leave a dead selection.
      if selection == nil || !ids.contains(selection!) {
        selection = ids.first
      }
    }
  }
}

private struct DisplayDetail: View {
  @Environment(\.motion) private var motion

  @Bindable var display: DisplayViewModel
  let log: DiagnosticsLog

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        controls
        configuration
        capabilities
        diagnostics
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(display.name)
  }

  private var controls: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 18) {
        labelled("Brightness", value: display.brightness) {
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
        }

        if display.supportsContrast {
          labelled("Contrast", value: display.contrast) {
            ExpressiveSlider(
              value: Binding(
                get: { display.contrast },
                set: { display.setContrast($0) }
              ),
              accent: display.accent,
              icon: "circle.lefthalf.filled"
            )
            .disabled(!display.isReady)
          }
        }

        if display.supportsVolume {
          labelled("Volume", value: display.volume) {
            ExpressiveSlider(
              value: Binding(
                get: { display.volume },
                set: { display.setVolume($0) }
              ),
              accent: display.accent,
              icon: "speaker.wave.2.fill"
            )
          }
        } else {
          Text("This display has no controllable volume.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(6)
    } label: {
      Label("Controls", systemImage: "slider.horizontal.3")
    }
  }

  private func labelled(
    _ title: String,
    value: Double,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.callout.weight(.medium))
        Spacer()
        Text("\(Int((value * 100).rounded()))%")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .animation(motion.effectFast, value: value)
      }
      content()
    }
  }

  private var configuration: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        Picker("Brightness via", selection: strategyBinding) {
          ForEach(BrightnessStrategy.allCases, id: \.self) { strategy in
            Text(strategy.displayName).tag(strategy)
          }
        }
        .help("Automatic picks the best available path. Override only if that choice is wrong.")

        Toggle("Keep dimming below the backlight minimum", isOn: extraDimmingBinding)
          .help("Once the backlight is at zero, continue with the gamma table. "
            + "Costs contrast and appears in screenshots.")

        Toggle("Brightness keys act on this display", isOn: mediaKeysBinding)

        Picker("Timing", selection: timingBinding) {
          Text("Standard").tag(DDCTiming.default)
          Text("Relaxed (for fussy panels)").tag(DDCTiming.relaxed)
        }
        .help("Increase this if readings fail intermittently or the display "
          + "ignores the first change after being idle.")

        accentPicker

        HStack {
          Button {
            Task { await display.reprobeCapabilities() }
          } label: {
            if display.isProbing {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Probing…")
              }
            } else {
              Text("Probe features again")
            }
          }
          .disabled(display.isProbing)

          Text("Takes a few seconds — one round trip per feature.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(6)
    } label: {
      Label("This display", systemImage: "gearshape")
    }
  }

  private var accentPicker: some View {
    HStack {
      Text("Accent")
      Spacer()
      // The default is derived from the display's identity, so the same monitor
      // keeps its colour across launches. The override is for when that choice
      // collides with a wallpaper.
      ForEach(Array(AccentPalette.tones.enumerated()), id: \.offset) { index, tone in
        let isSelected = display.settings.accentOverride == index
        Circle()
          .fill(tone)
          .frame(width: 16, height: 16)
          .overlay {
            Circle().strokeBorder(.primary, lineWidth: isSelected ? 2 : 0)
          }
          .onTapGesture {
            display.updateSettings { $0.accentOverride = isSelected ? nil : index }
          }
      }
    }
  }

  // Bindings that read from persisted settings and write through the view
  // model, so a change reaches the controllers and not just the checkbox.

  private var strategyBinding: Binding<BrightnessStrategy> {
    Binding(
      get: { display.settings.brightnessStrategy },
      set: { value in display.updateSettings { $0.brightnessStrategy = value } }
    )
  }

  private var extraDimmingBinding: Binding<Bool> {
    Binding(
      get: { display.settings.extraDimmingEnabled },
      set: { value in display.updateSettings { $0.extraDimmingEnabled = value } }
    )
  }

  private var mediaKeysBinding: Binding<Bool> {
    Binding(
      get: { display.settings.respondsToMediaKeys },
      set: { value in display.updateSettings { $0.respondsToMediaKeys = value } }
    )
  }

  private var timingBinding: Binding<DDCTiming> {
    Binding(
      get: { display.settings.timing },
      set: { value in display.updateSettings { $0.timing = value } }
    )
  }

  /// The point of showing this is the failures. When a slider is missing, this
  /// is where the reason is — "maximum is 0xFFFF" is a real answer, where a
  /// silently absent control is not.
  private var capabilities: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        if let probed = display.capabilities {
          ForEach(VCPCode.probeSet, id: \.rawValue) { vcp in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: probed.isUsable(vcp) ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(probed.isUsable(vcp) ? Color.green : .secondary)
                .font(.caption)
              Text(vcp.description)
                .font(.callout)
                .frame(width: 170, alignment: .leading)
              Text(detail(for: probed.support(for: vcp)))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text("Not probed yet.").font(.callout).foregroundStyle(.secondary)
        }
      }
      .padding(6)
    } label: {
      Label("Reported features", systemImage: "checklist")
    }
  }

  private func detail(for support: DisplayCapabilities.Support) -> String {
    switch support {
    case let .supported(current, maximum): "\(current) / \(maximum)"
    case let .implausible(_, _, reason): reason
    case .unsupported: "declined by the display"
    case let .unreachable(detail): detail
    }
  }

  private var diagnostics: some View {
    GroupBox {
      // Newest first: when something just broke, it is the top line that
      // matters.
      let records = log.snapshot().suffix(40).reversed()
      VStack(alignment: .leading, spacing: 2) {
        if records.isEmpty {
          Text("No activity recorded.").font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(Array(records), id: \.id) { record in
            Text(record.entry.message)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    } label: {
      Label("DDC log", systemImage: "text.alignleft")
    }
  }
}
