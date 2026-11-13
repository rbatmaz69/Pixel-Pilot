import CoreGraphics
import PixelPilotCore
import SwiftUI

/// One display's page in the settings window: every control the menu bar panel
/// offers, everything that can be configured about that particular monitor, and
/// the diagnostics needed to work out why one of them is missing.
struct DisplayPage: View {
  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var scheme
  /// The ambient wash stops when the window is not the one being used. A glow
  /// drifting away behind three other windows is pure cost.
  @Environment(\.controlActiveState) private var controlActive

  let model: AppModel
  @Bindable var display: DisplayViewModel
  let log: DiagnosticsLog
  /// Bumped whenever something outside this card changed the values in it.
  let groupChangeTick: Int

  @State private var displayModeRefreshTick = 0
  @State private var padDragPoint: CGPoint? = nil
  @State private var lastPadBrightnessDetent: Double? = nil
  @State private var lastPadKelvinDetent: Double? = nil
  @State private var heroHoverNorm: CGPoint? = nil
  @State private var heroCardSize: CGSize = .init(width: 560, height: 180)

  var body: some View {
    ScrollView {
      // No `GlassEffectContainer`: the cards stopped drawing glass — see
      // `CardSurface`, and `CardStack`, which lost the same wrapper for the
      // same reason.
      VStack(alignment: .leading, spacing: Layout.section) {
        card(0) { studioHeroCard }
        card(1) { controls }
          .accentWave(index: 0, trigger: groupChangeTick, accent: display.accent)
        card(2) { ColorSection(display: display) }
        card(3) { FinishSection(display: display) }
        card(4) { HealthSection(model: model, display: display) }
        if !display.isBuiltin {
          card(5) { InputAndPowerSection(display: display) }
        }
        card(6) { configuration }
        card(7) { diagnostics }
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
  }

  /// Normalized warmth fraction (`0.0` = warmest 2700K, `1.0` = neutral 6500K)
  /// used by the live StudioWallpaperCanvas preview.
  private var warmthFraction: Double {
    guard let kelvin = display.colorTemperatureKelvin else { return 1.0 }
    let span = ColorTemperature.range.upperBound - ColorTemperature.range.lowerBound
    guard span > 0 else { return 1.0 }
    return min(1, max(0, (kelvin - ColorTemperature.range.lowerBound) / span))
  }

  private var editorialSummary: String {
    let pct = "\(Int((display.brightness * 100).rounded())) % Helligkeit"
    let warmth = display.colorTemperatureKelvin.map { "\(Int($0.rounded())) K Wärme" } ?? "Natürlicher Weißpunkt"
    let finish = display.toneCurve.map { $0.namedFinish ?? "Individuelles Finish" } ?? "Klare Zeichnung"
    return "\(pct) · \(warmth) · \(finish)"
  }

  /// Live Studio-Monitor Hero-Card with physical MacBook / external monitor
  /// silhouette, real-time ambient backlight bleed on the studio wall, and
  /// tactile telemetry chips.
  private var studioHeroCard: some View {
    HStack(alignment: .center, spacing: Layout.loose) {
      studioMonitorStage
      studioHeroTelemetry
    }
    .padding(Layout.loose)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: display.accent, radius: Layout.radiusHero)
    .background {
      GeometryReader { geo in
        Color.clear
          .onAppear { heroCardSize = geo.size }
          .onChange(of: geo.size) { _, newSize in heroCardSize = newSize }
      }
    }
    .onContinuousHover { phase in
      guard controlActive != .inactive else {
        heroHoverNorm = nil
        return
      }
      switch phase {
      case let .active(location):
        let w = max(heroCardSize.width, 1)
        let h = max(heroCardSize.height, 1)
        heroHoverNorm = CGPoint(
          x: min(1, max(0, location.x / w)),
          y: min(1, max(0, location.y / h))
        )
      case .ended:
        heroHoverNorm = nil
      }
    }
    .animation(motion.effectFast, value: heroHoverNorm == nil)
    .accessibilityElement(children: .contain)
  }

  private var studioMonitorStage: some View {
    let clampedBrightness = min(1, max(0, display.brightness))
    let isScrubbing = padDragPoint != nil
    let hoverDx = (heroHoverNorm?.x ?? 0.5) - 0.5
    let hoverDy = (heroHoverNorm?.y ?? 0.5) - 0.5
    let haloWarmth = 1 - warmthFraction

    return ZStack {
      // Studio wall backdrop
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .fill(theme.recessedWell)

      // Warm walnut desk surface along the bottom edge
      VStack {
        Spacer()
        LinearGradient(
          colors: [
            Color(.sRGB, red: 0.24, green: 0.17, blue: 0.12, opacity: scheme == .dark ? 0.55 : 0.18),
            Color(.sRGB, red: 0.15, green: 0.10, blue: 0.07, opacity: scheme == .dark ? 0.72 : 0.28),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 26)
      }
      .clipShape(RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous))

      // Real-time ambient backlight bleed halo on the wall behind the monitor
      Ellipse()
        .fill(
          RadialGradient(
            colors: [
              display.accent.opacity((isScrubbing ? 0.24 : 0.14) + 0.36 * clampedBrightness),
              theme.studioAccent.opacity((isScrubbing ? 0.14 : 0.06) + 0.22 * haloWarmth),
              .clear,
            ],
            center: .center,
            startRadius: 4,
            endRadius: isScrubbing ? 112 : 96
          )
        )
        .frame(width: 196, height: 120)
        .scaleEffect(isScrubbing ? 1.16 : 1.0)
        .offset(x: hoverDx * 6, y: -6 + hoverDy * 4)
        .animation(motion.effectFast, value: isScrubbing)

      // Physical monitor silhouette (MacBook with notch/lip vs External Display with stand)
      VStack(spacing: 0) {
        studioMonitorScreen(clampedBrightness: clampedBrightness, hoverDx: hoverDx, hoverDy: hoverDy)

        if display.isBuiltin {
          // MacBook aluminum base lip
          RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.primary.opacity(0.42),
                  Color.primary.opacity(0.24),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .frame(width: 174, height: 5)
        } else {
          // External Studio Monitor stand neck & weighted base foot
          Rectangle()
            .fill(Color.primary.opacity(0.32))
            .frame(width: 14, height: 10)
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.40))
            .frame(width: 48, height: 4)
        }
      }
    }
    .frame(width: 214, height: 138)
    .overlay(
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .strokeBorder(theme.groupBorder, lineWidth: 1)
    )
  }

  private func studioMonitorScreen(
    clampedBrightness: Double,
    hoverDx: Double,
    hoverDy: Double
  ) -> some View {
    let screenSize = CGSize(width: 158, height: 94)
    let isScrubbing = padDragPoint != nil
    let pillText: String = if isScrubbing {
      "☀︎ \(percent(display.brightness)) · \(Int((display.colorTemperatureKelvin ?? ColorTemperature.neutralKelvin).rounded())) K"
    } else {
      percent(display.brightness)
    }
    let bezelShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let bezelStroke: Color = isScrubbing ? theme.studioAccent.opacity(0.9) : Color.black.opacity(0.82)
    let shadowColor = display.accent.opacity(0.12 + 0.24 * clampedBrightness)
    let shadowRadius: CGFloat = isScrubbing ? 15 : 12
    let shadowX: CGFloat = heroHoverNorm == nil ? 0 : -hoverDx * 7
    let shadowY: CGFloat = heroHoverNorm == nil ? 3 : 3 - hoverDy * 4

    return ZStack {
      StudioWallpaperCanvas(
        displayID: display.displayID,
        accent: display.accent,
        brightness: display.brightness,
        warmthFraction: warmthFraction,
        finish: display.toneCurve,
        isCompact: false
      )

      if let hoverNorm = heroHoverNorm {
        specularGlassGlint(at: hoverNorm, size: screenSize)
      }

      if let pt = padDragPoint {
        lightPadCrosshair(at: pt, size: screenSize)
      }

      if display.isBuiltin {
        macBookNotchOverlay
      }

      monitorReadoutPill(text: pillText, isScrubbing: isScrubbing)
    }
    .frame(width: screenSize.width, height: screenSize.height)
    .clipShape(bezelShape)
    .overlay(bezelShape.strokeBorder(bezelStroke, lineWidth: 2))
    .overlay(bezelShape.strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5))
    .shadow(color: shadowColor, radius: shadowRadius, x: shadowX, y: shadowY)
    .contentShape(.rect)
    .onTapGesture(count: 2) {
      cyclePaperFinish()
    }
    .gesture(lightPadGesture(in: screenSize))
    .help("Ziehen: Y = Helligkeit, X = Farbtemperatur · Doppelklick: Papier-Finish")
  }

  private var macBookNotchOverlay: some View {
    VStack(spacing: 0) {
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 3,
        bottomTrailingRadius: 3,
        topTrailingRadius: 0,
        style: .continuous
      )
      .fill(Color.black.opacity(0.88))
      .frame(width: 28, height: 5)
      Spacer(minLength: 0)
    }
  }

  private func monitorReadoutPill(text: String, isScrubbing: Bool) -> some View {
    VStack {
      Spacer()
      HStack {
        Spacer()
        Text(text)
          .font(TypeScale.detail.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.95))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule(style: .continuous)
              .fill(Color.black.opacity(isScrubbing ? 0.68 : 0.48))
          )
      }
      .padding(6)
    }
  }

  private func specularGlassGlint(at norm: CGPoint, size: CGSize) -> some View {
    let shiftX = (norm.x - 0.5) * size.width * 0.45
    let shiftY = (norm.y - 0.5) * size.height * 0.35
    return Rectangle()
      .fill(
        LinearGradient(
          colors: [
            .clear,
            Color.white.opacity(0.14),
            Color.white.opacity(0.05),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: size.width * 1.4, height: size.height * 1.4)
      .offset(x: shiftX, y: shiftY)
      .blendMode(.screen)
      .allowsHitTesting(false)
  }

  private func lightPadCrosshair(at point: CGPoint, size: CGSize) -> some View {
    let warmMix = 1 - warmthFraction
    let orbCore = Color(.sRGB, red: 1.0, green: 0.96 - 0.14 * warmMix, blue: 0.88 - 0.42 * warmMix)
    return ZStack(alignment: .topLeading) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: point.y))
        path.addLine(to: CGPoint(x: size.width, y: point.y))
        path.move(to: CGPoint(x: point.x, y: 0))
        path.addLine(to: CGPoint(x: point.x, y: size.height))
      }
      .stroke(Color.white.opacity(0.32), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))

      Circle()
        .fill(
          RadialGradient(
            colors: [orbCore, theme.studioAccent.opacity(0.65), .clear],
            center: .center,
            startRadius: 1,
            endRadius: 11
          )
        )
        .frame(width: 22, height: 22)
        .overlay(
          Circle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.2)
            .frame(width: 9, height: 9)
        )
        .position(point)
    }
    .allowsHitTesting(false)
  }

  private func lightPadGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        guard display.isReady else { return }
        let clampedX = min(size.width, max(0, value.location.x))
        let clampedY = min(size.height, max(0, value.location.y))
        padDragPoint = CGPoint(x: clampedX, y: clampedY)

        let normX = Double(clampedX / max(size.width, 1))
        let normY = Double(1 - clampedY / max(size.height, 1))

        let kelvin = KelvinTrack.warmRange.lowerBound
          + normX * (KelvinTrack.warmRange.upperBound - KelvinTrack.warmRange.lowerBound)

        let bDetent = SliderDetents.nearest(
          to: normY,
          among: SliderDetents.quarters,
          tolerance: 0.03
        )
        if let bDetent, bDetent != lastPadBrightnessDetent {
          Haptics.detent()
        }
        lastPadBrightnessDetent = bDetent

        let kDetents = [3500.0, 4500.0, 5500.0]
        let kDetent = kDetents.first { abs(kelvin - $0) <= 130 }
        if let kDetent, kDetent != lastPadKelvinDetent {
          Haptics.detent()
        }
        lastPadKelvinDetent = kDetent

        display.setBrightness(normY)
        display.setColorTemperature(kelvin >= 6450 ? nil : kelvin)
      }
      .onEnded { _ in
        padDragPoint = nil
        lastPadBrightnessDetent = nil
        lastPadKelvinDetent = nil
        display.commitBrightness()
      }
  }

  private func cyclePaperFinish() {
    guard display.isReady else { return }
    let next: ToneCurve? = switch display.toneCurve?.namedFinish {
    case nil: .paper
    case "Paper": .matte
    case "Matte": .ink
    default: nil
    }
    display.setToneCurve(next)
    Haptics.confirm()
  }

  private var studioHeroTelemetry: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      HStack(spacing: Layout.tight) {
        AccentDot(accent: display.accent, isReady: display.isReady, size: 7)
        Text(display.isBuiltin ? "INTEGRIERTES STUDIO-PANEL" : "EXTERNER STUDIO-MONITOR")
          .font(TypeScale.detail.weight(.semibold))
          .tracking(0.6)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(display.brightnessStrategy.displayName)
          .font(TypeScale.detail.weight(.semibold))
          .foregroundStyle(display.accent)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule(style: .continuous)
              .fill(display.accent.opacity(scheme == .dark ? 0.16 : 0.11))
          )
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(display.name)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(editorialSummary)
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .contentTransition(.numericText(value: display.brightness))
      }

      HStack(spacing: Layout.tight) {
        heroMetaBadge(
          symbol: "sun.max.fill",
          text: percent(display.brightness)
        )
        heroMetaBadge(
          symbol: "thermometer.sun",
          text: display.colorTemperatureKelvin.map { "\(Int($0.rounded())) K" } ?? "Neutral"
        )
        heroMetaBadge(
          symbol: "doc.plaintext",
          text: display.toneCurve.map { $0.namedFinish ?? "Individuell" } ?? "Standard"
        )
      }

      resolutionMenuPill

      Divider()
        .overlay(theme.separator)

      HStack(spacing: Layout.tight) {
        Text("Schnellwahl")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        ForEach([0.25, 0.50, 0.75, 1.0], id: \.self) { level in
          let isCurrent = abs(display.brightness - level) < 0.02
          Button(percent(level)) {
            display.setBrightness(level)
            display.commitBrightness()
          }
          .buttonStyle(.soft(isCurrent ? display.accent : .secondary))
          .controlSize(.small)
          .disabled(!display.isReady)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func heroMetaBadge(symbol: String, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(display.accent)
      Text(text)
        .font(TypeScale.detail)
        .monospacedDigit()
        .foregroundStyle(.primary.opacity(0.86))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
        .fill(theme.recessedWell)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
        .strokeBorder(theme.groupBorder, lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var resolutionMenuPill: some View {
    let _ = displayModeRefreshTick
    let summary = DisplayModeController.currentSummary(for: display.displayID)
    let options = DisplayModeController.availableOptions(for: display.displayID)

    if let summary {
      Menu {
        if options.isEmpty {
          Text("Keine weiteren HiDPI-/Hz-Modi verfügbar")
        } else {
          ForEach(options) { option in
            Button {
              if DisplayModeController.apply(option, to: display.displayID) {
                Haptics.confirm()
                displayModeRefreshTick &+= 1
              }
            } label: {
              let title = option.menuLabel
              if option.isCurrent {
                Label(title, systemImage: "checkmark")
              } else {
                Text(title)
              }
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "display")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(display.accent)
          Text(summary)
            .font(TypeScale.detail)
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.86))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
            .fill(theme.recessedWell)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
            .strokeBorder(theme.groupBorder, lineWidth: 0.5)
        )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("HiDPI-Skalierung und Bildwiederholrate schnell umschalten")
      .accessibilityLabel("Auflösung und Bildwiederholrate")
    }
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
    PanelCard(title: "Analoge Licht- & Ton-Regler", systemImage: "slider.horizontal.3", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.loose) {
        LabeledReadout(
          title: "Helligkeit",
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
            title: "Kontrast",
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
            title: "Monitor-Lautsprecher",
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
            title: "Keine Lautstärkeregelung",
            detail: reason
          )
          .transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: display.supportsVolume)
    }
  }

  private var configuration: some View {
    PanelCard(title: "Persönliche Abstimmung", systemImage: "gearshape", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Tastatur-Helligkeitstasten folgen diesem Display", isOn: mediaKeysBinding)

        Toggle("Mit Fokus-Dimmung abdunkeln", isOn: attentionBinding)
          .help("Senkt die Helligkeit leicht ab, wenn du auf einem anderen Bildschirm arbeitest.")

        if !display.isBuiltin {
          Divider()
          following
          Divider()
        }

        accentPicker
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
      Toggle("Helligkeit des integrierten Displays mitführen", isOn: Binding(
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
          title: "Kein integriertes Display aktiv",
          detail: "Folgt dem integrierten Mac-Bildschirm, sobald das MacBook aufgeklappt ist."
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
          Text("Integriert \(percent(source)) → dieses Display "
            + "\(percent(display.followCurve.target(forSource: source)))")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())

          Spacer(minLength: 0)

          Button("Jetzt abgleichen") { model.matchFollowNow(display) }
            .buttonStyle(.soft(display.accent))
            .font(TypeScale.detail.weight(.medium))
            .help("Merkt sich den aktuellen Unterschied für diese Umgebungshelligkeit")
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
          title: "Abfrage alle 5 Sekunden",
          detail: "Liest Änderungen vom internen Panel automatisch mit."
        )
      }

      CardFooter("Stelle den Regler im Dunkeln und im Hellen je einmal passend ein – Pixel Pilot lernt deine Kurve.")
    }
    .transition(.blurReplace)
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private var accentPicker: some View {
    HStack {
      Text("Monitor-Kennfarbe")
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
        accessibilityLabel: "Kennfarbe für \(display.name)"
      )
      .help("Akzentfarbe dieses Monitors in der Studio-Ansicht")
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
      title: "Diagnose & Technik",
      systemImage: "stethoscope",
      accent: display.accent,
      summary: "Transport-Override, DDC-Timing, erkannte Hardware-Funktionen und Testbilder."
    ) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        transportOverrides
        Divider()
        capabilities
        Divider()
        testPatterns
        Divider()
        ddcLog
      }
    }
  }

  private var transportOverrides: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("Helligkeit über").font(TypeScale.rowTitle)
        SegmentedMorphPicker(
          selection: strategyBinding,
          options: BrightnessStrategy.allCases.map { ($0, $0.displayName) },
          accent: display.accent
        )
      }
      .help("Automatisch wählt nahtlos zwischen Hardware (DDC) und Software.")

      Toggle("Unter das Backlight-Minimum dimmen (Software-Reserve)", isOn: extraDimmingBinding)
        .help("Dimmt unter 0 % Backlight per Software-Gamma-Tabelle weiter.")

      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("DDC-Bus-Timing").font(TypeScale.rowTitle)
        SegmentedMorphPicker(
          selection: timingBinding,
          options: [(DDCTiming.default, "Standard"), (DDCTiming.relaxed, "Entspannt")],
          accent: display.accent
        )
      }
      .help("Erhöhen, falls Werte sporadisch aussetzen oder nach Standby verschluckt werden.")

      HStack {
        Button {
          Task { await display.reprobeCapabilities() }
        } label: {
          if display.isProbing {
            HStack(spacing: Layout.tight) {
              ProgressView().controlSize(.small)
              Text("Wird geprüft…")
            }
            .transition(.blurReplace)
          } else {
            Text("Funktionen erneut prüfen")
              .transition(.blurReplace)
          }
        }
        .buttonStyle(.soft(display.accent))
        .disabled(display.isProbing)
        .animation(motion.spatialDefault, value: display.isProbing)

        Text("Dauert wenige Sekunden.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The other half of "why is this display wrong": everything above asks the
  /// panel about itself over DDC, and a panel that lies about its features will
  /// lie about the rest. These ask the pixels instead.
  private var testPatterns: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text("Testbilder").font(TypeScale.rowTitle)
      Text("Vollbild-Testmuster zur Prüfung auf Pixelfehler, Clouding und Verlauf.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button("Testbilder anzeigen") {
        model.showTestPatterns(on: display)
      }
      .buttonStyle(.soft)
    }
  }

  private var capabilities: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text("Erkannte Funktionen").font(TypeScale.rowTitle)

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
        Text("Noch nicht geprüft.").font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private func detail(for support: DisplayCapabilities.Support) -> String {
    switch support {
    case let .supported(current, maximum): "\(current) / \(maximum)"
    case let .implausible(_, _, reason): reason
    case .unsupported: "vom Display abgelehnt"
    case let .unreachable(detail): detail
    }
  }

  private var ddcLog: some View {
    // Newest first: when something just broke, it is the top line that
    // matters.
    let records = log.snapshot().suffix(40).reversed()
    return VStack(alignment: .leading, spacing: Layout.hair) {
      Text("DDC-Protokoll")
        .font(TypeScale.rowTitle)
        .padding(.bottom, Layout.hair)

      if records.isEmpty {
        Text("Keine Einträge aufgezeichnet.").font(.callout).foregroundStyle(.secondary)
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

/// Clean HiDPI / refresh-rate Quick-Switcher wrapper around CoreGraphics display modes.
@MainActor
private enum DisplayModeController {
  struct Option: Identifiable, Hashable, Sendable {
    let ioDisplayModeID: Int32
    let width: Int
    let height: Int
    let refreshHz: Int
    let isHiDPI: Bool
    let isCurrent: Bool
    let roleTag: String?

    var id: Int32 { ioDisplayModeID }

    var menuLabel: String {
      let base = refreshHz > 0 ? "\(width) × \(height) · \(refreshHz) Hz" : "\(width) × \(height)"
      let hidpi = isHiDPI ? " HiDPI" : ""
      if let roleTag {
        return "\(base)\(hidpi) — \(roleTag)"
      }
      return "\(base)\(hidpi)"
    }
  }

  static func currentSummary(for displayID: CGDirectDisplayID) -> String? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let hz = Int(mode.refreshRate.rounded())
    return hz > 0 ? "\(mode.width) × \(mode.height) · \(hz) Hz" : "\(mode.width) × \(mode.height)"
  }

  static func availableOptions(for displayID: CGDirectDisplayID) -> [Option] {
    let current = CGDisplayCopyDisplayMode(displayID)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      return []
    }

    let usable = raw.filter { $0.isUsableForDesktopGUI() && $0.width >= 800 && $0.height >= 600 }
    let hasHiDPI = usable.contains { $0.pixelWidth > $0.width }

    struct Key: Hashable {
      let width: Int
      let height: Int
      let hz: Int
      let isHiDPI: Bool
    }

    var deduped: [Key: CGDisplayMode] = [:]
    for mode in usable {
      let isHiDPI = mode.pixelWidth > mode.width
      if hasHiDPI && !isHiDPI && mode.width < (usable.map(\.pixelWidth).max() ?? mode.width) / 2 {
        continue
      }
      let key = Key(
        width: mode.width,
        height: mode.height,
        hz: Int(mode.refreshRate.rounded()),
        isHiDPI: isHiDPI
      )
      if let existing = deduped[key] {
        if current?.ioDisplayModeID == mode.ioDisplayModeID || mode.pixelWidth > existing.pixelWidth {
          deduped[key] = mode
        }
      } else {
        deduped[key] = mode
      }
    }

    let sorted: [CGDisplayMode] = deduped.values.sorted { lhs, rhs in
      if lhs.width != rhs.width { return lhs.width < rhs.width }
      let lhsHiDPI = lhs.pixelWidth > lhs.width
      let rhsHiDPI = rhs.pixelWidth > rhs.width
      if lhsHiDPI != rhsHiDPI { return lhsHiDPI }
      return lhs.refreshRate > rhs.refreshRate
    }

    let distinctWidths = Array(Set(sorted.map(\.width))).sorted()
    let minW = distinctWidths.first
    let midW = distinctWidths.count >= 3 ? distinctWidths[distinctWidths.count / 2] : nil
    let maxW = distinctWidths.count >= 2 ? distinctWidths.last : nil

    return sorted.map { mode in
      let tag: String? = switch mode.width {
      case let w where w == minW && distinctWidths.count >= 2: "Größerer Text"
      case let w where w == midW: "Standard"
      case let w where w == maxW && distinctWidths.count >= 2: "Mehr Fläche"
      default: nil
      }
      return Option(
        ioDisplayModeID: mode.ioDisplayModeID,
        width: mode.width,
        height: mode.height,
        refreshHz: Int(mode.refreshRate.rounded()),
        isHiDPI: mode.pixelWidth > mode.width,
        isCurrent: current?.ioDisplayModeID == mode.ioDisplayModeID,
        roleTag: tag
      )
    }
  }

  static func apply(_ option: Option, to displayID: CGDirectDisplayID) -> Bool {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
          let target = raw.first(where: { $0.ioDisplayModeID == option.ioDisplayModeID })
    else {
      return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
      return false
    }
    let configureStatus = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
    guard configureStatus == .success else {
      CGCancelDisplayConfiguration(config)
      return false
    }
    return CGCompleteDisplayConfiguration(config, .permanently) == .success
  }
}
