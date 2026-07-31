import PixelPilotCore
import SwiftUI

/// The full window: one display per sidebar row, with every control the panel
/// supports plus the diagnostics needed to work out why one of them is missing.
struct MainWindow: View {
  let model: AppModel

  @State private var selection: DisplayViewModel.ID?

  var body: some View {
    NavigationSplitView {
      // Still a `List` with a system selection rather than a custom stack with
      // a sliding pill. The pill would look better and would cost arrow-key
      // navigation of the sidebar, which is not a trade worth making for a
      // highlight.
      VStack(spacing: 0) {
        if model.displays.count > 1 {
          // Only with more than one. A map of a single display is a rectangle
          // saying what the row below it already says.
          DisplayMap(
            displays: model.displays,
            selection: $selection,
            layoutTick: model.screenLayoutTick
          )
          .padding(.horizontal, Layout.snug)
          .padding(.top, Layout.snug)

          Button {
            model.identifyDisplays()
          } label: {
            Label("Identify", systemImage: "number.circle")
              .font(TypeScale.detail.weight(.medium))
          }
          .buttonStyle(.soft)
          .padding(.vertical, Layout.tight)
        }

        List(model.displays, selection: $selection) { display in
          HStack(spacing: Layout.tight) {
            AccentDot(accent: display.accent, isReady: display.isReady, size: 9)
            VStack(alignment: .leading, spacing: 1) {
              Text(display.name).font(TypeScale.rowTitle)
              Text(display.isBuiltin ? "Built-in" : display.routeDescription)
                .font(TypeScale.detail)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 3)
          .tag(display.id)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      if let display = model.displays.first(where: { $0.id == selection }) {
        DisplayDetail(display: display, log: model.log, groupChangeTick: model.groupChangeTick)
      } else if model.displays.isEmpty {
        // Two empty states, not one. "Nothing is plugged in" and "nothing is
        // selected" are different problems with different next steps, and
        // `ContentUnavailableView` was telling both of them to pick from a
        // list that might have nothing in it.
        CharacterfulEmptyState(
          title: "Looking for displays",
          message: "Nothing is answering on the DDC bus yet. External monitors appear here "
            + "as soon as they are connected."
        ) {
          SearchingRadar()
        }
      } else {
        CharacterfulEmptyState(
          title: "Pick a display",
          message: "Choose one on the left to see its controls, what it really supports, "
            + "and what it has been saying back."
        ) {
          BreathingMonitor()
        }
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
  /// The ambient wash stops when the window is not the one being used. A glow
  /// drifting away behind three other windows is pure cost.
  @Environment(\.controlActiveState) private var controlActive

  @Bindable var display: DisplayViewModel
  let log: DiagnosticsLog
  /// Bumped whenever something outside this card changed the values in it.
  let groupChangeTick: Int

  @Namespace private var accentNamespace
  @State private var hoveredAccent: Int?

  var body: some View {
    ScrollView {
      // One backdrop pass for the column rather than one per card — see
      // `CardStack`, which does the same for the settings tabs.
      GlassEffectContainer(spacing: Layout.section) {
        VStack(alignment: .leading, spacing: Layout.section) {
          card(0) { controls }
            .accentWave(index: 0, trigger: groupChangeTick, accent: display.accent)
          if !display.isBuiltin {
            card(1) { InputAndPowerSection(display: display) }
          }
          card(2) { ColorSection(display: display) }
          card(3) { configuration }
          card(4) { capabilities }
          card(5) { diagnostics }
        }
      }
      .padding(Layout.loose)
      .frame(maxWidth: .infinity, alignment: .leading)
      // The display's own colour, not the app accent: everything else in this
      // column is tinted by which monitor it belongs to, and a switch that
      // stayed blue would be the one thing that did not.
      .toggleStyle(.morph(display.accent))
      // Switching displays rebuilds the column, so the cascade plays again and
      // the change reads as arriving rather than as a swap.
      .id(display.id)
    }
    .background(alignment: .top) {
      AmbientBackdrop(accent: display.accent, isVisible: controlActive != .inactive)
        .frame(height: 260)
    }
    .navigationTitle(display.name)
    // On demand, once ever per panel: six round trips is too much to spend at
    // connect time on a card most people will never open. Cached against the
    // `DisplayKey` after that, so this is a no-op on every later visit.
    .task(id: display.id) { await display.probeColorSupport() }
  }

  /// Cards fade rather than scale as they scroll.
  ///
  /// A scale would change the geometry the sliders map a drag into, and a
  /// handle that lands somewhere other than the pointer is a far worse bug than
  /// a missing flourish.
  private func card(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
    content()
      .scrollTransition { view, phase in
        view.opacity(phase.isIdentity ? 1 : 0.55)
      }
      .entrance(index: index)
  }

  /// Index zero, so this is a single pulse rather than a wave.
  ///
  /// The wave means "these several things moved together", and this window
  /// shows one display at a time. What is worth saying here is only that
  /// something changed the values from outside the card.
  private var controls: some View {
    PanelCard(title: "Controls", systemImage: "slider.horizontal.3", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.loose) {
        LabeledReadout(
          title: "Brightness",
          value: display.brightness,
          font: TypeScale.heroReadout,
          accent: display.accent
        ) {
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
          LabeledReadout(title: "Contrast", value: display.contrast, accent: display.accent) {
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
          LabeledReadout(title: "Volume", value: display.volume, accent: display.accent) {
            ExpressiveSlider(
              value: Binding(
                get: { display.volume },
                set: { display.setVolume($0) }
              ),
              accent: display.accent,
              icon: "speaker.wave.2.fill"
            )
          }
        } else if let reason = display.volumeUnavailableReason {
          // Explaining beats omitting: without this, "cannot" and "forgot"
          // look the same, and here the fix is often just switching output.
          StatusRow(
            symbol: "speaker.slash",
            title: "No volume control",
            detail: reason
          )
          .transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: display.supportsVolume)
    }
  }

  private var configuration: some View {
    PanelCard(title: "This display", systemImage: "gearshape", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Brightness via").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: strategyBinding,
            options: BrightnessStrategy.allCases.map { ($0, $0.displayName) },
            accent: display.accent
          )
        }
        .help("Automatic picks the best available path. Override only if that choice is wrong.")

        Toggle("Keep dimming below the backlight minimum", isOn: extraDimmingBinding)
          .help("Once the backlight is at zero, continue with the gamma table. "
            + "Costs contrast and appears in screenshots.")

        Toggle("Brightness keys act on this display", isOn: mediaKeysBinding)

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Timing").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: timingBinding,
            options: [(DDCTiming.default, "Standard"), (DDCTiming.relaxed, "Relaxed")],
            accent: display.accent
          )
        }
        .help("Increase this if readings fail intermittently or the display "
          + "ignores the first change after being idle.")

        accentPicker

        HStack {
          Button {
            Task { await display.reprobeCapabilities() }
          } label: {
            if display.isProbing {
              HStack(spacing: Layout.tight) {
                ProgressView().controlSize(.small)
                Text("Probing…")
              }
              .transition(.blurReplace)
            } else {
              Text("Probe features again")
                .transition(.blurReplace)
            }
          }
          .buttonStyle(.soft(display.accent))
          .disabled(display.isProbing)
          .animation(motion.spatialDefault, value: display.isProbing)

          Text("Takes a few seconds — one round trip per feature.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
      }
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
          .fill(tone.accentFill)
          .frame(width: 18, height: 18)
          .overlay {
            // One ring shared across all eight swatches, so picking a new
            // colour makes it travel there instead of blinking out here and in
            // again over there.
            if isSelected {
              Circle()
                .strokeBorder(.primary, lineWidth: 2)
                .matchedGeometryEffect(id: "accentRing", in: accentNamespace)
            }
          }
          .scaleEffect(hoveredAccent == index ? 1.25 : 1)
          .onHover { hovering in
            hoveredAccent = hovering ? index : (hoveredAccent == index ? nil : hoveredAccent)
          }
          .onTapGesture {
            display.updateSettings { $0.accentOverride = isSelected ? nil : index }
          }
          .help("Use this colour for \(display.name)")
      }
    }
    .animation(motion.spatialDefault, value: display.settings.accentOverride)
    .animation(motion.spatialFast, value: hoveredAccent)
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
    PanelCard(title: "Reported features", systemImage: "checklist", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.tight) {
        if let probed = display.capabilities {
          ForEach(VCPCode.probeSet, id: \.rawValue) { vcp in
            StatusRow(
              symbol: probed.isUsable(vcp) ? "checkmark.circle.fill" : "minus.circle",
              tint: probed.isUsable(vcp) ? Status.ok : nil,
              title: vcp.description,
              titleWidth: 170
            ) {
              Text(detail(for: probed.support(for: vcp)))
                .font(TypeScale.detail)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text("Not probed yet.").font(.callout).foregroundStyle(.secondary)
        }
      }
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
    PanelCard(title: "DDC log", systemImage: "text.alignleft", accent: display.accent) {
      // Newest first: when something just broke, it is the top line that
      // matters.
      let records = log.snapshot().suffix(40).reversed()
      VStack(alignment: .leading, spacing: Layout.hair) {
        if records.isEmpty {
          Text("No activity recorded.").font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(Array(records), id: \.id) { record in
            Text(record.entry.message)
              .font(TypeScale.mono)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
