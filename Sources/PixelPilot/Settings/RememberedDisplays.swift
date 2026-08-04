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
    PanelCard(title: "Remembered displays", systemImage: "externaldrive.badge.checkmark") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        if model.knownDisplays.isEmpty {
          Text("Nothing remembered yet. A display is recorded the first time it is probed.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.knownDisplays, id: \.key) { entry in
            let connected = model.isConnected(entry.key)
            StatusRow(
              symbol: connected ? "display" : "display.trianglebadge.exclamationmark",
              tint: connected ? Status.ok : nil,
              title: entry.settings.lastKnownName.isEmpty
                ? "Unnamed display" : entry.settings.lastKnownName,
              detail: connected ? "Connected" : "Not connected"
            ) {
              Button {
                forgetting = entry.key
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.soft)
              .help("Forget this display")
            }
            .transition(.blurReplace)
          }
        }

        CardFooter("A display is remembered by its panel, not by the port it is in, so "
          + "moving a cable keeps its settings. Forgetting one is how a monitor that has "
          + "been sold or reconfigured stops carrying its old settings around.")
      }
      .animation(motion.spatialDefault, value: model.knownDisplays.count)
    }
    .onAppear { model.refreshKnownDisplays() }
    .confirmationDialog(
      "Forget this display?",
      isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
      presenting: forgetting
    ) { key in
      Button("Forget", role: .destructive) {
        model.forgetDisplay(key)
        forgetting = nil
      }
      Button("Cancel", role: .cancel) { forgetting = nil }
    } message: { _ in
      // Naming what is actually lost, rather than asking "are you sure". The
      // expensive part is the capability cache: without it the panel is probed
      // again — six DDC round trips — the next time it appears.
      Text("Its accent colour, DDC timing and cached capabilities are discarded. The next "
        + "time it connects it will be probed again, which takes a few seconds.")
    }
  }
}
