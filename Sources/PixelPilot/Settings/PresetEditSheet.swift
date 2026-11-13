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

  @Environment(\.theme) private var theme

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespaces)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Preset bearbeiten")
          .font(TypeScale.sheetTitle)
        Text("Name und Symbol in der Menüleiste anpassen.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
      }

      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)

      VStack(alignment: .leading, spacing: Layout.tight) {
        Text("Symbol").font(TypeScale.rowTitle)
        SymbolChipPicker(
          selection: $symbolName,
          symbols: symbols,
          accessibilityLabel: "Preset-Symbol"
        )
      }

      CardFooter("Lichtwerte bleiben erhalten — aktualisiere sie direkt in den Presets über „Aktualisieren“.")

      Spacer(minLength: 0)

      HStack {
        Button("Abbrechen", role: .cancel, action: onCancel)
          .buttonStyle(.soft)
          .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Speichern", action: save)
          .buttonStyle(SoftButtonStyle(isProminent: true))
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty)
      }
    }
    .padding(Layout.loose)
    .frame(width: 440, height: 320)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .fill(theme.surface)
    }
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .strokeBorder(theme.specularRim, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous))
  }

  private func save() {
    guard !trimmedName.isEmpty else { return }
    var edited = preset
    edited.name = trimmedName
    edited.symbolName = symbolName
    onSave(edited)
  }
}
