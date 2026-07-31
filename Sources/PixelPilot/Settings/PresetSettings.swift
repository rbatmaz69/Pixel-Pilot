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

  @Environment(\.motion) private var motion

  @State private var newPresetName = ""
  @State private var selectedSymbol = "moon.fill"
  @Namespace private var symbolNamespace

  /// A small set rather than a full symbol browser — enough to tell presets
  /// apart in the menu bar at a glance.
  private let symbols = [
    "sun.max.fill", "moon.fill", "film.fill", "desktopcomputer",
    "gamecontroller.fill", "book.fill", "photo.fill", "eye.fill",
  ]

  var body: some View {
    CardStack {
      PanelCard(title: "Presets", systemImage: "square.stack") {
        VStack(alignment: .leading, spacing: Layout.snug) {
          if model.presetList.isEmpty {
            CharacterfulEmptyState(
              title: "No presets yet",
              message: "Set your displays the way you want them, then capture that below "
                + "and give it a name."
            ) {
              SearchingRadar(size: 60)
            }
            // Inside a card rather than filling a window, so the illustration
            // gets a smaller share than the copy.
            .padding(.vertical, -Layout.snug)
          } else {
            ForEach(model.presetList) { preset in
              presetRow(preset)
                // Capturing and deleting both happen with this list on screen.
                // Growing in and fading out is the difference between a list
                // that responds and one that flickers.
                .transition(.asymmetric(
                  insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                  removal: .opacity
                ))
            }
          }
        }
        .animation(motion.spatialDefault, value: model.presetList.count)
      }
      .entrance(index: 0)

      PanelCard(title: "Capture the current state", systemImage: "plus.circle") {
        VStack(alignment: .leading, spacing: Layout.normal) {
          symbolPicker

          HStack(spacing: Layout.snug) {
            TextField("Name", text: $newPresetName)
              .textFieldStyle(.roundedBorder)

            Button("Capture") {
              let name = newPresetName.trimmingCharacters(in: .whitespaces)
              guard !name.isEmpty else { return }
              _ = model.captureCurrentState(name: name, symbolName: selectedSymbol)
              newPresetName = ""
            }
            .buttonStyle(.soft)
            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
          }

          CardFooter("Stores the brightness and contrast of every connected display. "
            + "Input source is left out on purpose — switching inputs needs a confirmation, "
            + "which a preset cannot ask for.")
        }
      }
      .entrance(index: 1)

      appearanceCard.entrance(index: 2)
    }
  }

  /// The symbol for a new preset, as a row of chips.
  ///
  /// A `Picker` in a 70pt well showed one glyph at a time and made choosing an
  /// icon feel like filling in a form. All eight at once is both faster and the
  /// most obviously playful surface in the app, which is the right place to
  /// spend it.
  private var symbolPicker: some View {
    HStack(spacing: Layout.tight) {
      ForEach(symbols, id: \.self) { symbol in
        let isSelected = selectedSymbol == symbol
        Image(systemName: symbol)
          .font(.callout)
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .frame(width: 30, height: 28)
          .background {
            // One highlight for the whole row, so it slides to the chip you
            // pick instead of blinking out of one and into another.
            if isSelected {
              MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
                .fill(.tint.opacity(0.18))
                .matchedGeometryEffect(id: "symbolChip", in: symbolNamespace)
            }
          }
          .contentShape(.rect)
          .onTapGesture { selectedSymbol = symbol }
          .help(symbol)
      }
      Spacer(minLength: 0)
    }
    .animation(motion.spatialDefault, value: selectedSymbol)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Preset symbol")
  }

  private func presetRow(_ preset: Preset) -> some View {
    StatusRow(
      symbol: preset.symbolName,
      title: preset.name,
      detail: summary(for: preset)
    ) {
      HStack(spacing: Layout.tight) {
        Button("Apply") { model.apply(preset) }
          .buttonStyle(.soft)

        Button {
          model.deletePreset(id: preset.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.soft)
        .help("Delete this preset")
      }
      .font(TypeScale.detail.weight(.medium))
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

  private var appearanceCard: some View {
    PanelCard(title: "Automatic", systemImage: "circle.lefthalf.filled") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Switch presets with the system appearance", isOn: Binding(
          get: { model.appearanceBindings.isEnabled },
          set: { value in model.updateAppearanceBindings { $0.isEnabled = value } }
        ))

        ControlRow(title: "When light") {
          Picker("", selection: appearanceBinding(isDark: false)) {
            Text("Do nothing").tag(UUID?.none)
            ForEach(model.presetList) { preset in
              Text(preset.name).tag(UUID?.some(preset.id))
            }
          }
          .labelsHidden()
        }
        .disabled(!model.appearanceBindings.isEnabled)

        ControlRow(title: "When dark") {
          Picker("", selection: appearanceBinding(isDark: true)) {
            Text("Do nothing").tag(UUID?.none)
            ForEach(model.presetList) { preset in
              Text(preset.name).tag(UUID?.some(preset.id))
            }
          }
          .labelsHidden()
        }
        .disabled(!model.appearanceBindings.isEnabled)

        // Explaining the choice, because a schedule is the obvious thing to
        // look for and its absence is deliberate.
        CardFooter("Tied to light and dark rather than to a clock. macOS announces the "
          + "change, so nothing has to run in the background waiting for it — and following "
          + "sunrise properly would mean asking for your location.")
      }
      .animation(motion.effectDefault, value: model.appearanceBindings.isEnabled)
    }
  }

  private func appearanceBinding(isDark: Bool) -> Binding<UUID?> {
    Binding(
      get: {
        isDark
          ? model.appearanceBindings.darkPresetID
          : model.appearanceBindings.lightPresetID
      },
      set: { value in
        model.updateAppearanceBindings {
          if isDark { $0.darkPresetID = value } else { $0.lightPresetID = value }
        }
      }
    )
  }
}
