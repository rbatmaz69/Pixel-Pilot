import SwiftUI

// The last system chrome in the app.
//
// Every surface here is custom — the cards, the sliders, the buttons — and then
// the settings windows are full of stock `Toggle`s and `Picker`s. That seam is
// the most visible thing in the app, because it runs right through the middle
// of the two windows people spend the longest in.
//
// The replacements share `KnobGeometry` with `ExpressiveSlider` deliberately.
// One metrics table is what makes a switch and a slider read as two members of
// the same family rather than as two things that were each styled once.

// MARK: - Toggle

/// The app's switch.
///
/// A `ToggleStyle` rather than a bespoke view, and that is the whole design
/// decision. A style travels through the environment, so one
/// `.toggleStyle(.morph)` at the root of a tab converts every switch in it —
/// and each call site keeps its label, its `.help()`, its `.disabled()` and its
/// VoiceOver behaviour without being touched. A hand-rolled view would need all
/// of that added back at each of the nine call sites, and the tenth would get
/// it wrong.
struct MorphToggleStyle: ToggleStyle {
  var accent: Color?

  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration, accent: accent)
  }

  /// A nested view, for the same reason `SoftButtonStyle` has one: a style is
  /// not installed in the hierarchy, so `@Environment` read from the style
  /// itself would silently hand back defaults.
  private struct Surface: View {
    let configuration: Configuration
    let accent: Color?

    @Environment(\.motion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flip = 0

    private var tone: Color { accent ?? theme.tone }

    // Native macOS NSSwitch dimensions (36×20pt capsule, 16×16pt circular thumb).
    private static let trackWidth: CGFloat = 36
    private static let trackHeight: CGFloat = 20
    private static let padding: CGFloat = 2

    private var knobWidth: CGFloat {
      isPressed ? 19 : 16
    }

    var body: some View {
      HStack(spacing: Layout.snug) {
        configuration.label
        Spacer(minLength: Layout.snug)
        switchBody
      }
      .contentShape(.rect)
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { isHovered = $0 && isEnabled }
      .onTapGesture { toggle() }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in if isEnabled { isPressed = true } }
          .onEnded { _ in isPressed = false }
      )
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isToggle)
      .accessibilityValue(configuration.isOn ? Text("on") : Text("off"))
      .accessibilityAction { toggle() }
    }

    private var switchBody: some View {
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(
            configuration.isOn
              ? AnyShapeStyle(theme.fill(for: tone))
              : AnyShapeStyle(theme.recessedWell)
          )
          .overlay {
            Capsule(style: .continuous)
              .strokeBorder(
                configuration.isOn ? theme.rim(for: tone) : theme.groupBorder,
                lineWidth: 1
              )
          }
          .animation(motion.effectDefault, value: configuration.isOn)

        knob
      }
      .frame(width: Self.trackWidth, height: Self.trackHeight)
    }

    private var knob: some View {
      Capsule(style: .continuous)
        .fill(.white)
        .frame(width: knobWidth, height: Self.trackHeight - Self.padding * 2)
        .shadow(color: .black.opacity(isPressed ? 0.24 : 0.16), radius: isPressed ? 3 : 2, y: 1)
        .offset(x: knobOffset)
        .animation(motion.tactileSnap ?? motion.spatialDefault, value: configuration.isOn)
        .animation(motion.spatialFast, value: knobWidth)
    }

    private var knobOffset: CGFloat {
      let travel = Self.trackWidth - Self.padding * 2 - knobWidth
      return Self.padding + (configuration.isOn ? travel : 0)
    }

    private func toggle() {
      guard isEnabled else { return }
      configuration.isOn.toggle()
      flip += 1
      Haptics.detent()
    }
  }
}

extension ToggleStyle where Self == MorphToggleStyle {
  static var morph: MorphToggleStyle { MorphToggleStyle() }
  static func morph(_ accent: Color) -> MorphToggleStyle { MorphToggleStyle(accent: accent) }
}

// MARK: - Segmented picker

/// A short row of choices with one highlight that travels between them.
///
/// This shape had already been written twice by hand — the accent swatches in
/// the main window and the symbol chips in the preset settings — both with the
/// same `matchedGeometryEffect` trick and the same comment explaining it. The
/// third copy is where a pattern becomes a component.
///
/// For two to four fixed options only. Lists that grow at runtime stay as
/// menus; see `MorphMenuPicker`.
struct SegmentedMorphPicker<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(value: Value, title: String)]
  var accent: Color?

  @Environment(\.motion) private var motion
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.theme) private var theme
  @Namespace private var highlight
  @State private var hovered: Value?

  private var tone: Color { accent ?? theme.tone }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        segment(option)
      }
    }
    .padding(2)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
        .fill(theme.recessedWell)
        .overlay {
          RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
            .strokeBorder(theme.groupBorder, lineWidth: 1)
        }
    }
    .opacity(isEnabled ? 1 : 0.4)
    .animation(motion.tactileSnap ?? motion.expressiveSpring, value: selection)
    .accessibilityElement(children: .contain)
  }

  private func segment(_ option: (value: Value, title: String)) -> some View {
    let isSelected = selection == option.value

    return Text(option.title)
      .font(.callout.weight(isSelected ? .semibold : .regular))
      .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, Layout.snug)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
            .fill(theme.surfaceRaised)
            .overlay {
              RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
                .fill(theme.wash(for: tone))
            }
            .overlay {
              RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
                .strokeBorder(theme.rim(for: tone).opacity(0.65), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            .matchedGeometryEffect(id: "segment", in: highlight)
        }
      }
      .contentShape(.rect)
      .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
      .onTapGesture {
        guard isEnabled, !isSelected else { return }
        selection = option.value
        Haptics.detent()
      }
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityLabel(option.title)
  }
}

// MARK: - Menu picker

/// A menu whose trigger is ours and whose list is AppKit's.
///
/// The deliberate half-measure. Reimplementing the popup would mean
/// reimplementing type-select, VoiceOver and keyboard navigation, and losing
/// all three is a bad price for a hover animation on a control that is open for
/// a second at a time. So the button is styled and the list is left alone.
struct MorphMenuPicker<Content: View>: View {
  let title: String
  var accent: Color?
  @ViewBuilder var content: Content

  @Environment(\.theme) private var theme

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: Layout.tight) {
        Text(title)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .menuStyle(.button)
    .buttonStyle(.soft(accent ?? theme.tone))
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

// MARK: - Symbol chips

/// All the choices at once, as a row of glyphs.
///
/// Lifted out of the preset settings unchanged in behaviour. A `Picker` in a
/// 70 pt well showed one glyph at a time and made choosing an icon feel like
/// filling in a form; eight at once is both faster and the most obviously
/// playful surface in the app, which is the right place to spend it.
struct SymbolChipPicker: View {
  @Binding var selection: String
  let symbols: [String]
  var accent: Color?
  var accessibilityLabel: String

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Namespace private var chip

  private var tone: Color { accent ?? theme.tone }

  var body: some View {
    HStack(spacing: Layout.tight) {
      ForEach(symbols, id: \.self) { symbol in
        let isSelected = selection == symbol
        Image(systemName: symbol)
          .font(.callout)
          .foregroundStyle(isSelected ? AnyShapeStyle(tone) : AnyShapeStyle(.secondary))
          .symbolEffect(.bounce, value: isSelected)
          .frame(width: 30, height: 28)
          .background {
            // One highlight for the whole row, so it slides to the chip you
            // pick instead of blinking out of one and into another.
            if isSelected {
              MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
                .fill(theme.wash(for: tone))
                .matchedGeometryEffect(id: "symbolChip", in: chip)
            }
          }
          .contentShape(.rect)
          .onTapGesture {
            guard !isSelected else { return }
            selection = symbol
            Haptics.detent()
          }
          .help(symbol)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      }
      Spacer(minLength: 0)
    }
    .animation(motion.tactileSnap ?? motion.expressiveSpring, value: selection)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }
}
