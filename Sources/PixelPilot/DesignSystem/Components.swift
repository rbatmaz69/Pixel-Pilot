import SwiftUI

// The pieces every surface was rebuilding by hand: a titled card, a status
// line, a labelled percentage, the accent dot, and a button that responds to
// being pressed. Each of these existed in three or four near-identical private
// copies, which is how "nearly consistent" happens — the copies drift.

// MARK: - Surfaces

/// A titled card.
///
/// Replaces `GroupBox`, which draws a flat grey box with a label bolted above
/// it. This tints the surface with the display's own accent instead, so a
/// window showing two monitors is legible at a glance rather than after
/// reading the headings.
struct PanelCard<Content: View>: View {
  let title: String
  let systemImage: String
  var accent: Color = .accentColor
  @ViewBuilder var content: Content

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      HStack(spacing: Layout.tight) {
        Image(systemName: systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(accent.accentText(colorScheme))
          .frame(width: 22, height: 22)
          .background(Circle().fill(accent.accentWash))
        Text(title)
          .font(TypeScale.cardTitle)
        Spacer(minLength: 0)
      }

      content
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: accent)
  }
}

/// A column of cards, for a settings tab or any other page made of sections.
///
/// The counterpart to `Form(.grouped)`, which was the last thing in the app
/// still drawing system chrome: its sections come with their own radius and
/// their own inset, neither of which can be restyled, so a settings window kept
/// looking like a different application from the one it configures.
struct CardStack<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Layout.loose) {
        content
      }
      .padding(Layout.loose)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The closing note under a card's controls — the old `Section(footer:)`.
struct CardFooter: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(TypeScale.detail)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A label on the left, a control on the right.
///
/// Outside a `Form` nothing aligns the two for you, and a column of pickers
/// each as wide as its own longest option reads as a broken layout.
struct ControlRow<Control: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var control: Control

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.hair) {
      HStack {
        Text(title).font(TypeScale.rowTitle)
        Spacer(minLength: Layout.snug)
        control.fixedSize()
      }
      if let detail {
        Text(detail)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension View {
  /// The card background on its own, for places that carry their own heading.
  func cardSurface(accent: Color, radius: CGFloat = Layout.radiusCard) -> some View {
    background {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(.background.secondary)
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(accent.accentWash)
        }
    }
    .overlay {
      // A hairline rather than a border: the wash alone vanishes against a
      // light wallpaper, and without an edge the card stops being a card.
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(accent.accentRim, lineWidth: 1)
    }
  }
}

// MARK: - Rows

/// Icon, title, explanation, and an optional control on the right.
///
/// The shape four separate places had arrived at independently: permission
/// states, probed capabilities, the unlisted-input warning and the key-learning
/// verdict. The symbol animates on change because that is the moment worth
/// noticing — a permission being granted should not look like a redraw.
struct StatusRow<Trailing: View>: View {
  let symbol: String
  /// `nil` renders the glyph in the secondary hierarchy instead of a colour,
  /// for rows that are informational rather than good or bad news.
  var tint: Color?
  let title: String
  var detail: String?
  var titleWidth: CGFloat?
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Layout.tight) {
      Image(systemName: symbol)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .contentTransition(.symbolEffect(.replace))
        .symbolEffect(.bounce, value: symbol)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(TypeScale.rowTitle)
          .frame(width: titleWidth, alignment: .leading)
        if let detail {
          Text(detail)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: Layout.tight)

      trailing
    }
  }
}

extension StatusRow where Trailing == EmptyView {
  init(symbol: String, tint: Color? = nil, title: String, detail: String? = nil, titleWidth: CGFloat? = nil) {
    self.init(
      symbol: symbol, tint: tint, title: title,
      detail: detail, titleWidth: titleWidth, trailing: { EmptyView() }
    )
  }
}

/// A title with the value as a percentage, over its control.
///
/// The percentage rolls rather than jumps: `.numericText` plus monospaced
/// digits is what stops a changing value from twitching the row it sits in.
struct LabeledReadout<Content: View>: View {
  let title: String
  let value: Double
  var font: Font = TypeScale.readout
  var accent: Color = .accentColor
  @ViewBuilder var content: Content

  @Environment(\.motion) private var motion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int((value * 100).rounded()))%")
          .font(font)
          .foregroundStyle(accent.accentText(colorScheme))
          .contentTransition(.numericText(value: value))
          .animation(motion.effectFast, value: value)
      }
      content
    }
  }
}

/// The per-display colour dot.
///
/// While the display is not answering yet, a ripple runs out of it. That loop
/// only exists while this view does — closing the panel takes the whole
/// hierarchy with it — and it is replaced by a static ring under reduced
/// motion, where a repeating pulse is exactly the thing being asked about.
struct AccentDot: View {
  let accent: Color
  var isReady: Bool = true
  var size: CGFloat = 8

  @Environment(\.motion) private var motion

  var body: some View {
    Circle()
      .fill(accent.accentFill)
      .frame(width: size, height: size)
      .overlay { ring }
      .shadow(color: accent.accentGlow(isReady), radius: 4)
      .opacity(isReady ? 1 : 0.55)
      .animation(motion.effectDefault, value: isReady)
  }

  @ViewBuilder
  private var ring: some View {
    let ring = Circle().strokeBorder(accent, lineWidth: 1.5)

    if !isReady {
      if motion.isReduced {
        ring.opacity(0.5)
      } else {
        // Three phases rather than two: a two-phase animator would play the
        // ripple in reverse on the way back, which reads as the dot inhaling.
        // The middle phase resets the scale while the ring is invisible.
        ring.phaseAnimator([0, 1, 2]) { content, phase in
          content
            .scaleEffect(phase == 1 ? 2.6 : 1)
            .opacity(phase == 0 ? 0.6 : 0)
        } animation: { phase in
          switch phase {
          case 1: .easeOut(duration: 1.1)
          case 2: .linear(duration: 0.01)
          default: .easeIn(duration: 0.3)
          }
        }
      }
    }
  }
}

// MARK: - Buttons

/// The app's button.
///
/// `.accessoryBar` gives a correct but inert control: it highlights and that is
/// all. This sinks under the press and springs back on release, which is the
/// difference between a button that responds and one that feels like anything.
struct SoftButtonStyle: ButtonStyle {
  var accent: Color?
  /// Filled rather than merely tinted, for the one action a surface is about.
  var isProminent = false

  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration, accent: accent, isProminent: isProminent)
  }

  // A nested view rather than styling `configuration.label` directly: a
  // `ButtonStyle` is not installed in the hierarchy, so `@Environment` read
  // from the style itself would silently return defaults. It cannot be called
  // `Body` either — that name collides with the protocol's own requirement.
  private struct Surface: View {
    let configuration: Configuration
    let accent: Color?
    let isProminent: Bool

    @Environment(\.motion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var tone: Color { accent ?? .accentColor }

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium))
        .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, Layout.snug)
        .padding(.vertical, Layout.tight)
        .background {
          MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
            .fill(fill)
        }
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        // Down is quick and flat, up rings: pressing should feel immediate,
        // releasing should feel elastic. One curve for both loses that.
        .animation(configuration.isPressed ? motion.effectFast : motion.expressive,
                   value: configuration.isPressed)
        .animation(motion.effectFast, value: isHovered)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 && isEnabled }
        .contentShape(.rect)
    }

    private var fill: AnyShapeStyle {
      if isProminent {
        return AnyShapeStyle(tone.accentFill)
      }
      if configuration.isPressed {
        return AnyShapeStyle(tone.opacity(0.26))
      }
      return AnyShapeStyle(isHovered ? tone.accentWash : Color.primary.opacity(0.06))
    }
  }
}

extension ButtonStyle where Self == SoftButtonStyle {
  static var soft: SoftButtonStyle { SoftButtonStyle() }
  static func soft(_ accent: Color) -> SoftButtonStyle { SoftButtonStyle(accent: accent) }
}

// MARK: - Entrance

extension View {
  /// A staggered arrival, played once when the view appears.
  ///
  /// This is where most of the liveliness comes from, and it is free: the menu
  /// bar panel's hierarchy is built fresh every time it opens, so the sequence
  /// plays on every click and nothing at all is running in between.
  func entrance(index: Int) -> some View {
    modifier(Entrance(index: index))
  }
}

private struct Entrance: ViewModifier {
  let index: Int

  @Environment(\.motion) private var motion
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown ? 1 : 0.96, anchor: .top)
      .offset(y: shown ? 0 : 10)
      // Keyed to `shown` rather than wrapped in `withAnimation`. These cards
      // contain sliders, and a slider's knob position must never be animated —
      // a transaction opened up here would reach it.
      .animation(entranceCurve, value: shown)
      // Flipped in `onAppear` rather than initialised true, so there is one
      // frame of the "before" state to animate away from.
      .onAppear { shown = true }
  }

  private var entranceCurve: Animation {
    // Capped, because the panel can hold more displays than the cascade reads
    // well for. Past the eighth the last one arrives late enough to look like
    // a hitch rather than a rhythm.
    motion.spatialSlow.delay(Double(min(index, 8)) * motion.stagger)
  }
}
