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
        PanelCard(title: "Your presets", systemImage: "square.stack") {
          VStack(alignment: .leading, spacing: Layout.snug) {
            ForEach(model.presetList) { preset in
              row(for: .preset(preset.id), label: preset.name, symbol: preset.symbolName)
            }

            CardFooter("A shortcut for one particular preset. The Presets card above steps "
              + "through the whole list instead, which is the one to bind when the list is "
              + "long.")
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
      // The old text here said shortcuts act on the display under the pointer.
      // That was true before there was a setting for it, and has been wrong
      // since — the default has been the focused window for some time.
      "These follow the setting under Keys: the screen you are working on, the one under "
        + "the pointer, or all of them at once. “Everywhere” ignores that and always moves "
        + "the whole group, keeping the differences between screens. Shortcuts have no "
        + "finer step — the modifiers that get one out of a keyboard key are already part "
        + "of the shortcut itself."
    case .sound:
      "The display's own speakers when it has them, and the system output when it does not."
    case .presets:
      "Steps through the presets in the order they are listed, wrapping at both ends, and "
        + "carries on from whichever one was applied last — including one applied by the "
        + "schedule or by an app. The indicator says where you landed."
    case .app:
      "They work anywhere, including over full-screen apps, and need no extra permission."
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
