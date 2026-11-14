import PixelPilotCore
import ServiceManagement
import SwiftUI

/// Erscheinungsbild, Studio-Glas, Systemstart und Einführung.
struct GeneralSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  private var theme: ThemeStore { .shared }

  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchAtLoginError: String?

  var body: some View {
    CardStack {
      appearanceCard.entrance(index: 0)
      startupAndGuideCard.entrance(index: 1)
    }
  }

  private var appearanceCard: some View {
    PanelCard(title: "Erscheinungsbild & Studio-Glas", systemImage: "paintpalette") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Erscheinungsbild").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: Binding(
              get: { theme.mode },
              set: { newMode in
                theme.mode = newMode
                if theme.backdropToneIndex != nil { theme.backdropToneIndex = nil }
                if theme.style != .glass { theme.style = .glass }
              }
            ),
            options: [
              (.light, "☀︎ \(theme.triplet.lightSubtitle)"),
              (.dark, "🌙 \(theme.triplet.darkSubtitle)"),
              (.system, "Automatisch"),
            ]
          )
        }

        VStack(alignment: .leading, spacing: Layout.tight) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Farb-Triplet (60 · 30 · 10)").font(TypeScale.rowTitle)
            Text("Abgestimmter Dreiklang aus Hintergrund, Struktur & Akzent")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          }
          TripletThemePicker(
            selection: Binding(
              get: { theme.triplet },
              set: { theme.triplet = $0 }
            )
          )
        }

        LabeledReadout(title: "Liquid Glass Deckkraft", value: theme.glassOpacity) {
          ExpressiveSlider(
            value: Binding(
              get: { theme.glassOpacity },
              set: { theme.glassOpacity = $0 }
            ),
            range: GlobalSettings.glassOpacityRange,
            accent: theme.theme.tone,
            icon: "rectangle.portrait.on.rectangle.portrait.angled",
            detents: []
          )
          .accessibilityLabel("Liquid Glass Deckkraft")
        }

        ControlRow(
          title: "Tageszeit-Atmosphäre",
          detail: "Lichtstimmung für Popover, Seitenleiste und Studio-Header"
        ) {
          MorphMenuPicker(title: theme.ambientMoodPreference.displayName) {
            ForEach(AmbientMoodPreference.allCases, id: \.self) { preference in
              Button {
                theme.ambientMoodPreference = preference
              } label: {
                if theme.ambientMoodPreference == preference {
                  Label(preference.displayName, systemImage: "checkmark")
                } else {
                  Text(preference.displayName)
                }
              }
            }
          }
        }

        Toggle(
          "Helligkeit in der Menüleiste anzeigen (%)",
          isOn: Binding(
            get: { model.showsMenuBarPercentage },
            set: { model.showsMenuBarPercentage = $0 }
          )
        )

        CardFooter(
          "Jedes Farb-Triplet stimmt Hintergrund (60 %), Karten & Tinte (30 %) "
            + "sowie Studio-Akzent (10 %) in heller und dunkler Variante aufeinander ab. "
            + "Die Glas-Deckkraft wirkt direkt auf Popover, Seitenleiste und HUD."
        )
      }
    }
  }

  private var startupAndGuideCard: some View {
    PanelCard(title: "Systemstart & Einführung", systemImage: "sparkles") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        VStack(alignment: .leading, spacing: Layout.tight) {
          Toggle("Beim Anmelden automatisch im Studio bereitstehen", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
          if let launchAtLoginError {
            Text(launchAtLoginError)
              .font(TypeScale.detail)
              .foregroundStyle(Status.bad)
              .fixedSize(horizontal: false, vertical: true)
              .transition(.blurReplace)
          }
        }
        .animation(motion.spatialDefault, value: launchAtLoginError)

        HStack {
          Button("Willkommens-Tour zeigen…") { model.showWelcome() }
            .buttonStyle(.soft)
          Spacer()
        }

        CardFooter(
          "Zeigt die Einrichtung von Eingabehilfen, Hardware-Tasten und Menüleisten-Menü jederzeit erneut."
        )
      }
    }
  }

  /// `SMAppService` registration fails for an unsigned or ad-hoc signed build,
  /// so the error is surfaced cleanly instead of silently reverting.
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
      launchAtLoginError = "Anmelde-Status konnte nicht geändert werden: \(error.localizedDescription)"
    }
  }
}
