import PixelPilotCore
import SwiftUI

/// One display's page in the settings window: every control the menu bar panel
/// offers, everything that can be configured about that particular monitor, and
/// the diagnostics needed to work out why one of them is missing.
struct DisplayPage: View {
  @Environment(\.motion) private var motion
  /// The ambient wash stops when the window is not the one being used. A glow
  /// drifting away behind three other windows is pure cost.
  @Environment(\.controlActiveState) private var controlActive

  let model: AppModel
  @Bindable var display: DisplayViewModel
  let log: DiagnosticsLog
  /// Bumped whenever something outside this card changed the values in it.
  let groupChangeTick: Int

  var body: some View {
    ScrollView {
      // No `GlassEffectContainer`: the cards stopped drawing glass — see
      // `CardSurface`, and `CardStack`, which lost the same wrapper for the
      // same reason.
      VStack(alignment: .leading, spacing: Layout.section) {
        card(0) { controls }
          .accentWave(index: 0, trigger: groupChangeTick, accent: display.accent)
        if !display.isBuiltin {
          card(1) { InputAndPowerSection(display: display) }
        }
        card(2) { ColorSection(display: display) }
        card(3) { FinishSection(display: display) }
        card(4) { configuration }
        card(5) { diagnostics }
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
    .scrollContentBackground(.hidden)
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
          accent: display.accent,
          // Typed figures take the same path a released handle does: set, then
          // settle. Anything else would make "40 by hand" and "40 by keyboard"
          // two different writes to the same register.
          onCommit: { value in
            display.setBrightness(value)
            display.commitBrightness()
          }
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
          LabeledReadout(
            title: "Contrast",
            value: display.contrast,
            accent: display.accent,
            onCommit: { display.setContrast($0) }
          ) {
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
          LabeledReadout(
            title: "Volume",
            value: display.volume,
            accent: display.accent,
            onCommit: { display.setVolume($0) }
          ) {
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

        Toggle("This display sinks back when you're working elsewhere", isOn: attentionBinding)
          .help("Only has an effect while Attention is switched on, under Keys. "
            + "Turn it off for a screen that is watched rather than worked on.")

        if !display.isBuiltin {
          Divider()
          following
          Divider()
        }

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

  /// Letting the room drive this display.
  ///
  /// The built-in panel is the source rather than the light sensor, because
  /// macOS has already turned that sensor into a brightness — one calibrated to
  /// this Mac and to the habits of the person using it. Reading the result is a
  /// better signal than any curve this app could keep.
  @ViewBuilder
  private var following: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Toggle("Follow the built-in display's brightness", isOn: Binding(
        get: { display.followsBuiltinBrightness },
        set: { model.setFollowsBuiltinBrightness($0, for: display) }
      ))
      .disabled(model.builtinDisplay == nil)

      if model.builtinDisplay == nil {
        // Explained rather than quietly hidden, for the reason spelled out on
        // `volumeUnavailableReason`: "cannot" and "forgot" look identical from
        // out here, and here the fix is often just opening the lid.
        StatusRow(
          symbol: "laptopcomputer.slash",
          title: "No built-in display right now",
          detail: "This follows the Mac's own screen, because that is the one macOS "
            + "adjusts to the light in the room. On a laptop, opening the lid is "
            + "enough; a Mac with no display of its own has nothing to follow."
        )
      } else if display.followsBuiltinBrightness {
        mapping
      }
    }
    .animation(motion.spatialDefault, value: display.followsBuiltinBrightness)
  }

  private var mapping: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      if let source = model.builtinSource.current {
        HStack(alignment: .firstTextBaseline, spacing: Layout.snug) {
          // The mapping as a sentence rather than a graph. Two anchors and a
          // line between them is not worth a chart, and what someone wants to
          // know standing here is only "what is it doing right now".
          Text("Built-in \(percent(source)) → this display "
            + "\(percent(display.followCurve.target(forSource: source)))")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())

          Spacer(minLength: 0)

          Button("Match now") { model.matchFollowNow(display) }
            .buttonStyle(.soft(display.accent))
            .font(TypeScale.detail.weight(.medium))
            .help("Remember this display's current brightness for whenever the "
              + "built-in one is back at \(percent(source))")
        }
        .animation(motion.effectFast, value: source)
      }

      if model.builtinSource.mode == .polling {
        // The one recurring timer in this application. It runs only while this
        // is switched on, and saying so is the same bargain the HID switch in
        // Settings makes.
        StatusRow(
          symbol: "timer",
          tint: Status.info,
          title: "Asking every five seconds",
          detail: "This system does not announce brightness changes, so they have to "
            + "be checked for. Turning this off stops that entirely."
        )
      }

      CardFooter("Just move the slider above whenever this is wrong, and it is "
        + "remembered for that light level — dim it once in a dark room and once "
        + "in a bright one and it has what it needs. Presets and the schedule "
        + "still win the moment they are applied, until the room next changes.")
    }
    .transition(.blurReplace)
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private var accentPicker: some View {
    HStack {
      Text("Accent")
      Spacer()
      // The default is derived from the display's identity, so the same monitor
      // keeps its colour across launches. The override is for when that choice
      // collides with a wallpaper — and clearing it goes back to the derived
      // one, which is why this picker allows none and the theme's does not.
      AccentSwatchPicker(
        selection: Binding(
          get: { display.settings.accentOverride },
          set: { value in display.updateSettings { $0.accentOverride = value } }
        ),
        accessibilityLabel: "Accent colour for \(display.name)"
      )
      .help("The colour this display is shown in")
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

  /// Unlike its neighbours this one also nudges the controller, because the veil
  /// is applied from outside this display's own view model — persisting the
  /// opt-out would otherwise leave the screen sunk until the next window change.
  private var attentionBinding: Binding<Bool> {
    Binding(
      get: { display.settings.dimsWhenUnfocused },
      set: { value in
        display.updateSettings { $0.dimsWhenUnfocused = value }
        model.attentionSettingsChanged()
      }
    )
  }

  private var timingBinding: Binding<DDCTiming> {
    Binding(
      get: { display.settings.timing },
      set: { value in display.updateSettings { $0.timing = value } }
    )
  }

  /// What the display said it can do, and what it has been saying since.
  ///
  /// Folded away, and the two halves are one card rather than two: both are
  /// here for the same question — a control is missing or misbehaving, why —
  /// and neither is worth its height on the way to moving a slider. The point
  /// of showing them at all is the failures. "Maximum is 0xFFFF" is a real
  /// answer where a silently absent control is not.
  private var diagnostics: some View {
    DisclosureCard(
      title: "Diagnostics",
      systemImage: "stethoscope",
      accent: display.accent,
      summary: "What this display reports it can do, and what it has been saying back."
    ) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        capabilities
        Divider()
        testPatterns
        Divider()
        ddcLog
      }
    }
  }

  /// The other half of "why is this display wrong": everything above asks the
  /// panel about itself over DDC, and a panel that lies about its features will
  /// lie about the rest. These ask the pixels instead.
  private var testPatterns: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text("Test patterns").font(TypeScale.rowTitle)
      Text("Fills this screen with images for finding dead pixels, banding, backlight "
        + "bleed and scaling. Click or press → to move through them, esc to leave.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button("Show test patterns") {
        model.showTestPatterns(on: display)
      }
      .buttonStyle(.soft)
    }
  }

  private var capabilities: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text("Reported features").font(TypeScale.rowTitle)

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

  private func detail(for support: DisplayCapabilities.Support) -> String {
    switch support {
    case let .supported(current, maximum): "\(current) / \(maximum)"
    case let .implausible(_, _, reason): reason
    case .unsupported: "declined by the display"
    case let .unreachable(detail): detail
    }
  }

  private var ddcLog: some View {
    // Newest first: when something just broke, it is the top line that
    // matters.
    let records = log.snapshot().suffix(40).reversed()
    return VStack(alignment: .leading, spacing: Layout.hair) {
      Text("DDC log")
        .font(TypeScale.rowTitle)
        .padding(.bottom, Layout.hair)

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
