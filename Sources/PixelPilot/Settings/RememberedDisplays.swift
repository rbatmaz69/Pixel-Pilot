import PixelPilotCore
import SwiftUI

/// Every panel the app has ever configured, and a way to let one go.
///
/// Settings follow the panel rather than the port, which is what makes a
/// monitor keep its configuration across a replug — and also what means a
/// monitor that is sold, returned or reconfigured keeps its old settings
/// forever with nothing to clear them.
///
/// Under Displays rather than with the app's own settings, and last in that
/// section: it is the only page there about monitors that are *not* plugged in,
/// which is also why it is the one thing left to look at when nothing is.
struct RememberedDisplays: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  /// The display awaiting a "yes, forget it".
  @State private var forgetting: DisplayKey?

  var body: some View {
    CardStack {
      rememberedCard.entrance(index: 0)
    }
  }

  private var rememberedCard: some View {
    PanelCard(title: "Bekannte Displays", systemImage: "externaldrive.badge.checkmark") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("Jedes Panel behält seine Kalibrierung, auch wenn das Kabel den Port wechselt.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)

        if model.knownDisplays.isEmpty {
          Text("Noch keine Displays gespeichert. Monitore werden beim ersten Verbinden automatisch erfasst.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.knownDisplays, id: \.key) { entry in
            let connected = model.isConnected(entry.key)
            StatusRow(
              symbol: connected ? "display" : "display.trianglebadge.exclamationmark",
              tint: connected ? Status.ok : nil,
              title: entry.settings.lastKnownName.isEmpty
                ? "Unbenanntes Display" : entry.settings.lastKnownName,
              detail: connected ? "Verbunden" : "Nicht verbunden"
            ) {
              Button {
                forgetting = entry.key
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.soft)
              .help("Dieses Display vergessen")
            }
            .transition(.blurReplace)
          }
        }

        CardFooter("Einstellungen folgen dem physischen Panel statt dem Port.")
      }
      .animation(motion.spatialDefault, value: model.knownDisplays.count)
    }
    .onAppear { model.refreshKnownDisplays() }
    .confirmationDialog(
      "Dieses Display vergessen?",
      isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
      presenting: forgetting
    ) { key in
      Button("Vergessen", role: .destructive) {
        model.forgetDisplay(key)
        forgetting = nil
      }
      Button("Abbrechen", role: .cancel) { forgetting = nil }
    } message: { _ in
      Text("Akzentfarbe, DDC-Timing und gespeicherte Hardware-Fähigkeiten werden beim nächsten Verbinden neu eingelesen.")
    }
  }
}
