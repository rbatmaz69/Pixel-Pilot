import PixelPilotCore
import SwiftUI

/// Tastatur-Tasten, Fokus-Dimmung, Systemberechtigungen und Erkennung.
struct KeySettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  @State private var global = Preferences.shared.global
  @State private var isLearningKey = false

  var body: some View {
    CardStack {
      keysCard.entrance(index: 0)
      attentionCard.entrance(index: 1)
      permissionsCard.entrance(index: 2)
      detectionCard.entrance(index: 3)
    }
    .animation(motion.spatialDefault, value: model.needsRelaunchForPermissions)
    .onAppear { model.refreshPermissions() }
    .sheet(isPresented: $isLearningKey) {
      KeyLearningSheet(model: model, isPresented: $isLearningKey)
        .withMotionTokens()
    }
  }

  private var keysCard: some View {
    PanelCard(title: "Tastatur-Tasten", systemImage: "keyboard") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Helligkeits- und Lautstärketasten übernehmen", isOn: $global.mediaKeysEnabled)
          .onChange(of: global.mediaKeysEnabled) { _, _ in apply() }

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Tasten wirken auf").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: $global.keyTarget,
            options: KeyTarget.allCases.map { ($0, $0.displayName) }
          )
          .onChange(of: global.keyTarget) { _, _ in apply() }
          Text(global.keyTarget.summary)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
        .animation(motion.effectDefault, value: global.keyTarget)

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Schrittweite pro Tastendruck").font(TypeScale.rowTitle)
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

        Toggle("Schwebendes Studio-HUD anzeigen", isOn: $global.showsOSD)
          .onChange(of: global.showsOSD) { _, _ in apply() }

        Toggle("Trackpad-Haptik an Rastern & Endanschlägen", isOn: $global.hapticsEnabled)
          .onChange(of: global.hapticsEnabled) { _, _ in apply() }

        CardFooter("Mit ⇧+⌥ sind feinere Zwischenschritte möglich.")
      }
    }
  }

  private var attentionCard: some View {
    PanelCard(title: "Fokus-Dimmung", systemImage: "rectangle.inset.filled.on.rectangle") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Inaktive Displays sanft abdunkeln", isOn: $global.attention.isEnabled)
          .onChange(of: global.attention.isEnabled) { _, _ in apply() }

        if global.attention.isEnabled {
          amountSlider.transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
        }

        CardFooter(global.attention.isEnabled
          ? "Reduziert ungenutzte Displays per LUT ohne DDC-Verzögerung."
          : "Aus — alle Displays behalten ihre volle Helligkeit.")
      }
      .animation(motion.spatialDefault, value: global.attention.isEnabled)
    }
  }

  private var amountSlider: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text("Absenkung")
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int((global.attention.amount * 100).rounded()))%")
          .font(TypeScale.readout)
          .contentTransition(.numericText(value: global.attention.amount))
          .animation(motion.effectFast, value: global.attention.amount)
      }

      ExpressiveSlider(
        value: $global.attention.amount,
        range: AttentionSettings.amountRange,
        accent: theme.tone,
        detents: [],
        onCommit: { _ in apply() }
      )
    }
  }

  private var permissionsCard: some View {
    PanelCard(title: "Systemberechtigungen", systemImage: "lock.shield") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        PermissionRow(
          title: "Bedienungshilfen",
          detail: "Erforderlich, um Helligkeits- und Lautstärketasten global abzufangen.",
          isGranted: model.accessibilityGranted,
          action: model.requestAccessibilityPermission
        )
        PermissionRow(
          title: "Eingabeüberwachung",
          detail: "Erforderlich für Drittanbieter-Tastaturen über HID.",
          isGranted: model.inputMonitoringGranted,
          action: model.requestInputMonitoringPermission
        )

        if model.needsAccessibilityPermission || model.needsInputMonitoringPermission {
          CardFooter("Nach einem Update ggf. den alten Eintrag in den Systemeinstellungen mit „−“ neu hinzufügen.")
        }

        if model.needsRelaunchForPermissions {
          Divider()
          StatusRow(
            symbol: "arrow.clockwise.circle.fill",
            tint: Status.info,
            title: "Neustart zum Aktivieren erforderlich",
            detail: "Die Berechtigung wurde erteilt und wird beim nächsten Start aktiv."
          ) {
            Button("Neu starten") { model.relaunch() }
              .buttonStyle(.soft(Status.info))
              .font(TypeScale.detail.weight(.medium))
          }
          .transition(.blurReplace)
        }
      }
    }
  }

  private var detectionCard: some View {
    PanelCard(title: "Tastenerkennung", systemImage: "dot.radiowaves.left.and.right") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        VStack(alignment: .leading, spacing: Layout.hair) {
          if model.watchedKeyboards.isEmpty {
            Text("Keine Tastatur aktiv überwacht.")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          } else {
            Text("Überwacht: \(model.watchedKeyboards.joined(separator: ", "))")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if let observed = model.lastObservedKey {
            Text(String(
              format: "Letzte Taste: Usage 0x%02X (%@)", observed.usage, observed.device
            ))
            .font(TypeScale.mono)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
          } else {
            Text("Noch keine Sondertaste erkannt — drücke jetzt eine.")
              .font(TypeScale.detail)
              .foregroundStyle(.tertiary)
          }
        }
        .animation(motion.effectDefault, value: model.lastObservedKey?.usage)

        learnedKeys

        Divider()

        VStack(alignment: .leading, spacing: Layout.hair) {
          Toggle("Tasten zusätzlich auf Hardware-Ebene lesen (HID)", isOn: $global.hidMediaKeysEnabled)
            .onChange(of: global.hidMediaKeysEnabled) { _, _ in apply() }
          CardFooter("Für externe Tastaturen ohne macOS-Übersetzung; ohne HID bleibt die App bei 0 % Idle-Last.")
        }
      }
    }
  }

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
          .help("Taste vergessen")
        }
        .transition(.blurReplace)
      }

      HStack(spacing: Layout.tight) {
        Button("Taste anlernen…") { isLearningKey = true }
          .buttonStyle(.soft)
        Text("Für Tastaturen, deren Helligkeitstasten nicht direkt erkannt werden.")
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
    model.attentionSettingsChanged()
  }
}
