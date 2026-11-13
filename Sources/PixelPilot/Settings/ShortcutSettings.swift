import PixelPilotCore
import SwiftUI

/// Global shortcuts, a card per subject.
///
/// One card was right for five rows and is not right for fifteen: a list that
/// long is one nobody reads to the end of, and the thing being looked for is
/// always "the one that does X", never "the eleventh". Grouping is by what the
/// shortcut acts on, which is how somebody hunting for one already thinks —
/// `HotkeyCenter.Action.Builtin.Group` owns the split so the cards and the
/// actions cannot drift apart on it.
struct ShortcutSettings: View {
  let model: AppModel

  var body: some View {
    CardStack {
      ForEach(Array(HotkeyCenter.Action.Builtin.Group.allCases.enumerated()), id: \.element) {
        index, group in
        card(for: group).entrance(index: index)
      }

      if !model.presetList.isEmpty {
        PanelCard(title: "Deine Presets", systemImage: "square.stack") {
          VStack(alignment: .leading, spacing: Layout.snug) {
            ForEach(model.presetList) { preset in
              row(for: .preset(preset.id), label: preset.name, symbol: preset.symbolName)
            }

            CardFooter("Direkter Kurzbefehl für ein einzelnes Preset.")
          }
        }
        .entrance(index: HotkeyCenter.Action.Builtin.Group.allCases.count)
      }
    }
  }

  private func card(for group: HotkeyCenter.Action.Builtin.Group) -> some View {
    PanelCard(title: group.title, systemImage: group.symbolName) {
      VStack(alignment: .leading, spacing: Layout.snug) {
        ForEach(HotkeyCenter.Action.Builtin.allCases.filter { $0.group == group }, id: \.self) {
          builtin in
          row(for: .builtin(builtin), label: builtin.displayName, symbol: builtin.symbolName)
        }

        if let footer = footer(for: group) {
          CardFooter(footer)
        }
      }
    }
  }

  private func footer(for group: HotkeyCenter.Action.Builtin.Group) -> String? {
    switch group {
    case .displays:
      "Folgt dem Ziel unter Tasten & Fokus („Aktives Fenster“, „Unter dem Zeiger“ oder „Alle Displays“)."
    case .sound:
      "Nutzt Monitor-Lautsprecher sofern vorhanden, sonst die Systemausgabe."
    case .presets:
      "Wechselt reihum durch alle Presets; das Studio-HUD zeigt den aktiven Treffer."
    case .app:
      "Funktioniert global und auch über Vollbild-Apps ohne Zusatzberechtigung."
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
