import PixelPilotCore
import SwiftUI

/// Renaming a preset, and changing the symbol it wears in the menu bar.
///
/// Deliberately only those two. Everything else about a preset is captured by
/// setting the displays up and pressing the update button — see the comment at
/// the top of `PresetSettings`, which argues that asking for "brightness: 30%"
/// up front gets the order backwards. A name and a symbol are the two things
/// there is no way to arrive at by looking at a screen, so they are the two
/// things this sheet is for.
struct PresetEditSheet: View {
  let preset: Preset
  let symbols: [String]
  let onSave: (Preset) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @State private var symbolName: String

  init(
    preset: Preset,
    symbols: [String],
    onSave: @escaping (Preset) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preset = preset
    self.symbols = symbols
    self.onSave = onSave
    self.onCancel = onCancel
    // Seeded from the preset rather than bound to it: an edit that is cancelled
    // has to leave nothing behind, and the menu bar reads this list live.
    _name = State(initialValue: preset.name)
    _symbolName = State(initialValue: preset.symbolName)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespaces)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      Text("Edit preset")
        .font(TypeScale.sheetTitle)

      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)

      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("Symbol").font(TypeScale.rowTitle)
        SymbolChipPicker(
          selection: $symbolName,
          symbols: symbols,
          accessibilityLabel: "Preset symbol"
        )
      }

      // What this sheet does *not* touch, said plainly. Otherwise "Edit" reads
      // as a promise of a numbers editor, and its absence reads as an omission
      // rather than as the design.
      CardFooter("The values stay as they are. To change what this preset does, set the "
        + "displays up the way you want them and press its update button.")

      Spacer(minLength: 0)

      HStack {
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Save", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty)
      }
    }
    .padding(Layout.loose)
    .frame(width: 440, height: 300)
    // A sheet is a container, not a card, so it takes the container radius —
    // the same reasoning as `KeyLearningSheet`.
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous)
        .fill(.background)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous))
  }

  private func save() {
    guard !trimmedName.isEmpty else { return }
    var edited = preset
    edited.name = trimmedName
    edited.symbolName = symbolName
    onSave(edited)
  }
}
