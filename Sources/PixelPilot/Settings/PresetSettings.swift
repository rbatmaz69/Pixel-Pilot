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
  /// The preset whose values are being shown, after a hover has lasted long
  /// enough to be deliberate.
  @State private var previewed: UUID?
  @State private var previewTask: Task<Void, Never>?

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
            // A `List` nested inside the card, purely for `onMove`. That looks
            // like a lot of chrome to suppress for a drag handle, and it is —
            // but it also brings keyboard-accessible reordering and correct
            // VoiceOver drag semantics, which a hand-rolled `.draggable` would
            // have to reimplement and would get wrong.
            List {
              ForEach(model.presetList) { preset in
                presetRow(preset)
                  .listRowSeparator(.hidden)
                  .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                  .listRowBackground(Color.clear)
                  // Capturing and deleting both happen with this list on
                  // screen. Growing in and fading out is the difference between
                  // a list that responds and one that flickers.
                  .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                  ))
              }
              .onMove { source, destination in
                model.movePresets(fromOffsets: source, toOffset: destination)
                Haptics.detent()
              }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            // The card is what scrolls, so the list has to be exactly as tall
            // as its rows. A fixed guess would either clip the last preset or
            // leave a gap under the first.
            .frame(height: listHeight)
            .animation(motion.spatialDefault, value: listHeight)
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

  private var symbolPicker: some View {
    SymbolChipPicker(
      selection: $selectedSymbol,
      symbols: symbols,
      accessibilityLabel: "Preset symbol"
    )
  }

  /// One collapsed preset row, insets included.
  private static let rowHeight: CGFloat = 46
  /// One line of the preview strip.
  private static let previewLineHeight: CGFloat = 17

  /// How tall the nested list has to be made.
  ///
  /// A `List` inside a card cannot size itself to its content — it will happily
  /// be whatever height it is given and scroll the rest, which here means
  /// silently hiding presets. So the height is computed, and these two
  /// constants are tied to `presetRow`'s layout: change one and this has to
  /// change with it.
  private var listHeight: CGFloat {
    var height = CGFloat(model.presetList.count) * Self.rowHeight
    if let previewed, let preset = model.presetList.first(where: { $0.id == previewed }) {
      height += CGFloat(preset.affectedDisplays.count) * Self.previewLineHeight + Layout.tight
    }
    return height
  }

  private func presetRow(_ preset: Preset) -> some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
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

      if previewed == preset.id {
        preview(of: preset)
          .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
      }
    }
    .contentShape(.rect)
    .onHover { hovering in
      // A cancellable sleep, not a timer. Nothing is scheduled while the
      // pointer is anywhere else, and moving across the list on the way to
      // something else never opens anything.
      previewTask?.cancel()
      guard hovering else {
        previewed = nil
        return
      }
      previewTask = Task {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        previewed = preset.id
      }
    }
    .animation(motion.spatialDefault, value: previewed)
  }

  /// What the preset would actually set, as read-only tracks.
  ///
  /// The summary line above names the displays; this says what would happen to
  /// them. Between the two, applying a preset stops being a guess — which
  /// matters most for the presets captured months ago.
  private func preview(of preset: Preset) -> some View {
    let known = model.preferences.knownDisplays()

    return VStack(alignment: .leading, spacing: 3) {
      ForEach(preset.affectedDisplays.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { key in
        if let entry = preset.entry(for: key) {
          HStack(spacing: Layout.tight) {
            Text(known[key]?.lastKnownName.isEmpty == false
              ? known[key]!.lastKnownName
              : "unknown display")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
              .frame(width: 110, alignment: .leading)
              .lineLimit(1)

            if let brightness = entry.brightness {
              miniTrack(brightness, symbol: "sun.max.fill")
            }
            if let contrast = entry.contrast {
              miniTrack(contrast, symbol: "circle.lefthalf.filled")
            }
            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(.leading, 22)
  }

  private func miniTrack(_ value: Double, symbol: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
        .font(.system(size: 8))
        .foregroundStyle(.tertiary)
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary).frame(width: 44, height: 4)
        Capsule().fill(.tint).frame(width: max(2, 44 * value), height: 4)
      }
      Text("\(Int((value * 100).rounded()))%")
        .font(TypeScale.detail.monospacedDigit())
        .foregroundStyle(.secondary)
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

        ControlRow(title: "When light") { presetMenu(isDark: false) }
          .disabled(!model.appearanceBindings.isEnabled)

        ControlRow(title: "When dark") { presetMenu(isDark: true) }
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

  /// The preset list grows at runtime, so this stays a menu — only its trigger
  /// is ours. See `MorphMenuPicker` for why that line is drawn there.
  private func presetMenu(isDark: Bool) -> some View {
    let binding = appearanceBinding(isDark: isDark)
    let selected = model.presetList.first { $0.id == binding.wrappedValue }

    return MorphMenuPicker(title: selected?.name ?? "Do nothing") {
      Button("Do nothing") { binding.wrappedValue = nil }
      if !model.presetList.isEmpty { Divider() }
      ForEach(model.presetList) { preset in
        Button {
          binding.wrappedValue = preset.id
        } label: {
          Label(preset.name, systemImage: preset.symbolName)
        }
      }
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
