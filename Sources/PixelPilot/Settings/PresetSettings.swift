import PixelPilotCore
import SwiftUI

/// Managing presets.
///
/// Presets are created by capturing the current state rather than by typing
/// numbers into fields. Setting a display up by eye and then naming the result
/// is how people actually arrive at one; asking for "brightness: 30%" up front
/// gets the order backwards.
struct PresetSettings: View {
  let model: AppModel

  @State private var newPresetName = ""
  @State private var selectedSymbol = "moon.fill"
  @State private var renaming: Preset?

  /// A small set rather than a full symbol browser — enough to tell presets
  /// apart in the menu bar at a glance.
  private let symbols = [
    "sun.max.fill", "moon.fill", "film.fill", "desktopcomputer",
    "gamecontroller.fill", "book.fill", "photo.fill", "eye.fill",
  ]

  var body: some View {
    Form {
      Section {
        if model.presets.presets.isEmpty {
          Text("No presets yet. Set your displays the way you want them, then capture that below.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(model.presets.presets) { preset in
            presetRow(preset)
          }
        }
      } header: {
        Text("Presets")
      }

      Section("Capture the current state") {
        HStack(spacing: 10) {
          Picker("", selection: $selectedSymbol) {
            ForEach(symbols, id: \.self) { symbol in
              Image(systemName: symbol).tag(symbol)
            }
          }
          .labelsHidden()
          .frame(width: 70)

          TextField("Name", text: $newPresetName)
            .textFieldStyle(.roundedBorder)

          Button("Capture") {
            let name = newPresetName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            _ = model.captureCurrentState(name: name, symbolName: selectedSymbol)
            newPresetName = ""
          }
          .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        Text("Stores the brightness and contrast of every connected display. "
          + "Input source is left out on purpose — switching inputs needs a confirmation, "
          + "which a preset cannot ask for.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      appearanceSection
    }
    .formStyle(.grouped)
  }

  private func presetRow(_ preset: Preset) -> some View {
    HStack(spacing: 10) {
      Image(systemName: preset.symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(preset.name)
        Text(summary(for: preset))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Apply") { model.apply(preset) }
        .buttonStyle(.borderless)

      Button {
        model.deletePreset(id: preset.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete this preset")
    }
  }

  /// Names the displays a preset touches, so a preset captured with a monitor
  /// that is currently unplugged is recognisable rather than mysterious.
  private func summary(for preset: Preset) -> String {
    let keys = preset.affectedDisplays
    guard !keys.isEmpty else { return "affects nothing" }

    let known = model.preferences.knownDisplays()
    let names = keys.map { key in
      known[key]?.lastKnownName.isEmpty == false ? known[key]!.lastKnownName : "unknown display"
    }
    return names.sorted().joined(separator: ", ")
  }

  @ViewBuilder
  private var appearanceSection: some View {
    Section {
      Toggle("Switch presets with the system appearance", isOn: Binding(
        get: { model.presets.appearanceBindings.isEnabled },
        set: { value in model.presets.updateAppearanceBindings { $0.isEnabled = value } }
      ))

      Picker("When light", selection: appearanceBinding(isDark: false)) {
        Text("Do nothing").tag(UUID?.none)
        ForEach(model.presets.presets) { preset in
          Text(preset.name).tag(UUID?.some(preset.id))
        }
      }
      .disabled(!model.presets.appearanceBindings.isEnabled)

      Picker("When dark", selection: appearanceBinding(isDark: true)) {
        Text("Do nothing").tag(UUID?.none)
        ForEach(model.presets.presets) { preset in
          Text(preset.name).tag(UUID?.some(preset.id))
        }
      }
      .disabled(!model.presets.appearanceBindings.isEnabled)
    } header: {
      Text("Automatic")
    } footer: {
      // Explaining the choice, because a schedule is the obvious thing to look
      // for and its absence is deliberate.
      Text("Tied to light and dark rather than to a clock. macOS announces the change, "
        + "so nothing has to run in the background waiting for it — and following sunrise "
        + "properly would mean asking for your location.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func appearanceBinding(isDark: Bool) -> Binding<UUID?> {
    Binding(
      get: {
        isDark
          ? model.presets.appearanceBindings.darkPresetID
          : model.presets.appearanceBindings.lightPresetID
      },
      set: { value in
        model.presets.updateAppearanceBindings {
          if isDark { $0.darkPresetID = value } else { $0.lightPresetID = value }
        }
      }
    )
  }
}
