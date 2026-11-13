import AppKit
import PixelPilotCore
import SwiftUI

/// "When this app is in front, use that preset."
///
/// Event-driven and free at rest: `NSWorkspace` announces the frontmost app, so
/// nothing is watching for it. The same observer the permission check already
/// uses carries this too.
struct AppRuleSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  var body: some View {
    CardStack {
      rulesCard.entrance(index: 0)
      fallbackCard.entrance(index: 1)
    }
  }

  private var rulesCard: some View {
    PanelCard(title: "App-spezifische Presets", systemImage: "app.badge") {
      VStack(alignment: .leading, spacing: Layout.snug) {
        Text("Rückt eine verknüpfte App in den Fokus, wechselt das Studio-Licht nahtlos mit.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)

        if model.presetList.isEmpty {
          Text("Erstelle zuerst ein Preset — App-Regeln wählen zwischen vorhandenen Presets.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          if model.appRuleList.isEmpty {
            CharacterfulEmptyState(
              title: "Noch keine App-Regeln",
              message: "Wähle eine App und das passende Studio-Preset."
            ) {
              SearchingRadar(size: 56)
            }
            .padding(.vertical, -Layout.snug)
          }

          ForEach(model.appRuleList) { rule in
            ruleRow(rule)
              .transition(.blurReplace.combined(with: .scale(0.96, anchor: .leading)))
          }

          Button("Programm wählen…") { chooseApplication() }
            .buttonStyle(SoftButtonStyle(isProminent: true))
            .font(TypeScale.detail.weight(.medium))
        }
      }
      .animation(motion.spatialDefault, value: model.appRuleList.count)
    }
  }

  private func ruleRow(_ rule: AppRule) -> some View {
    HStack(spacing: Layout.snug) {
      AppIcon(bundleIdentifier: rule.bundleIdentifier)

      VStack(alignment: .leading, spacing: 1) {
        Text(rule.name).font(TypeScale.rowTitle)
        Text(presetName(rule.presetID) ?? "Preset fehlt")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: Layout.snug)

      MorphMenuPicker(title: presetName(rule.presetID) ?? "Auswählen") {
        ForEach(model.presetList) { preset in
          Button {
            var updated = rule
            updated.presetID = preset.id
            model.saveAppRule(updated)
          } label: {
            Label(preset.name, systemImage: preset.symbolName)
          }
        }
      }
      .font(TypeScale.detail)

      Button {
        model.deleteAppRule(id: rule.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.soft)
      .font(TypeScale.detail)
      .help("Regel entfernen")
    }
  }

  private var fallbackCard: some View {
    PanelCard(title: "Standard für alle anderen", systemImage: "arrow.uturn.backward") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        ControlRow(title: "Wenn keine Regel greift") {
          MorphMenuPicker(
            title: model.fallbackPresetID.flatMap(presetName) ?? "Nichts ändern"
          ) {
            Button("Nichts ändern") { model.setFallbackPreset(nil) }
            if !model.presetList.isEmpty { Divider() }
            ForEach(model.presetList) { preset in
              Button {
                model.setFallbackPreset(preset.id)
              } label: {
                Label(preset.name, systemImage: preset.symbolName)
              }
            }
          }
        }

        CardFooter("Reagiert ereignisgesteuert auf App-Wechsel (0 % Idle-Last).")
      }
    }
  }

  private func presetName(_ id: UUID) -> String? {
    model.presetList.first { $0.id == id }?.name
  }

  /// `NSOpenPanel` rather than a list of running applications: a rule for an
  /// app that happens not to be open right now is a perfectly ordinary thing to
  /// want to set up.
  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"

    guard panel.runModal() == .OK,
          let url = panel.url,
          let bundle = Bundle(url: url),
          let identifier = bundle.bundleIdentifier,
          let preset = model.presetList.first
    else { return }

    let name = FileManager.default.displayName(atPath: url.path)
    model.saveAppRule(
      AppRule(bundleIdentifier: identifier, name: name, presetID: preset.id)
    )
  }
}

