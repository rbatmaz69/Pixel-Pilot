import PixelPilotCore
import SwiftUI

struct ShortcutSettings: View {
  let model: AppModel

  var body: some View {
    CardStack {
      PanelCard(title: "Global shortcuts", systemImage: "command") {
        VStack(alignment: .leading, spacing: Layout.snug) {
          ForEach(HotkeyCenter.Action.Builtin.allCases, id: \.self) { builtin in
            row(for: .builtin(builtin), label: builtin.displayName)
          }

          CardFooter("Shortcuts act on the display under the pointer. They work anywhere, "
            + "including over full-screen apps, and need no extra permission.")
        }
      }
      .entrance(index: 0)

      if !model.presetList.isEmpty {
        PanelCard(title: "Presets", systemImage: "square.stack") {
          VStack(alignment: .leading, spacing: Layout.snug) {
            ForEach(model.presetList) { preset in
              row(for: .preset(preset.id), label: preset.name, symbol: preset.symbolName)
            }
          }
        }
        .entrance(index: 1)
      }
    }
  }

  private func row(
    for action: HotkeyCenter.Action,
    label: String,
    symbol: String? = nil
  ) -> some View {
    StatusRow(symbol: symbol ?? "command", title: label) {
      ShortcutRecorder(shortcut: model.hotkeys.shortcut(for: action)) { shortcut in
        model.setHotkey(shortcut, for: action)
      }
    }
  }
}
