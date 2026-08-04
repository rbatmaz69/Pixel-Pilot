import AppKit
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
  /// Left unset by everything that is not about one particular display, and
  /// then it is the theme's — which is what makes a settings page take the
  /// chosen colour without every card being told to.
  var accent: Color?
  @ViewBuilder var content: Content

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  private var tone: Color { accent ?? theme.tone }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      CardHeader(title: title, systemImage: systemImage, tone: tone)

      content
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: tone, isRaised: isHovered)
    // Lift by translation and shadow, never by scale.
    //
    // These cards contain sliders, and a `scaleEffect` changes the coordinate
    // space `ExpressiveSlider` maps `gesture.location.x` into — the handle
    // would land somewhere other than the pointer. The scroll transition below
    // already refused a scale for this exact reason; a hover effect is not a
    // good enough excuse to make the trade the second time.
    //
    // One point, and none of it under reduced motion: a card that twitches
    // under the pointer is precisely what that setting is asking to stop.
    .offset(y: isHovered && !motion.isReduced ? -1 : 0)
    .animation(motion.spatialFast, value: isHovered)
    .onHover { isHovered = $0 }
  }
}

/// A card whose contents are folded away until they are asked for.
///
/// For the sections that answer "why is this not working" rather than "what do
/// I want" — worth having on the page, not worth its height every time the page
/// is opened. The whole heading is the control rather than the chevron alone: a
/// glyph the size of a full stop is a poor target for something the rest of the
/// row is already advertising.
struct DisclosureCard<Content: View>: View {
  let title: String
  let systemImage: String
  /// Same convention as `PanelCard`: unset means the theme's colour.
  var accent: Color?
  /// What is behind the fold, said while it is shut. Without this a closed card
  /// is a title and an arrow, which is an invitation to open it just to find
  /// out whether it was worth opening.
  var summary: String?
  @ViewBuilder var content: Content

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var isExpanded = false
  @State private var isHovered = false

  private var tone: Color { accent ?? theme.tone }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Button {
        isExpanded.toggle()
      } label: {
        CardHeader(title: title, systemImage: systemImage, tone: tone) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        // The heading's own row, gaps included — otherwise the target is the
        // text and the glyph, with dead space between them.
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")

      if isExpanded {
        content.transition(.blurReplace)
      } else if let summary {
        Text(summary)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.blurReplace)
      }
    }
    .padding(Layout.normal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: tone, isRaised: isHovered)
    .offset(y: isHovered && !motion.isReduced ? -1 : 0)
    .animation(motion.spatialFast, value: isHovered)
    // Spatial rather than an effect curve: the card below this one has to
    // travel, and that is a change of position however it was triggered.
    .animation(motion.spatialDefault, value: isExpanded)
    .onHover { isHovered = $0 }
  }
}

/// The icon, the title, and whatever the card puts on the right of them.
///
/// Shared by `PanelCard` and `DisclosureCard` because the two must be the same
/// heading — a card that folds should not announce itself in a different voice
/// from the card above it.
private struct CardHeader<Trailing: View>: View {
  let title: String
  let systemImage: String
  let tone: Color
  @ViewBuilder var trailing: Trailing

  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: Layout.tight) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.ink(for: tone))
        .frame(width: 22, height: 22)
        .background(Circle().fill(theme.wash(for: tone)))
      Text(title)
        .font(TypeScale.cardTitle)
        .foregroundStyle(.primary)
      Spacer(minLength: 0)
      trailing
    }
  }
}

extension CardHeader where Trailing == EmptyView {
  init(title: String, systemImage: String, tone: Color) {
    self.init(title: title, systemImage: systemImage, tone: tone, trailing: { EmptyView() })
  }
}

/// A column of cards, for a settings page or any other page made of sections.
///
/// The counterpart to `Form(.grouped)`, which was the last thing in the app
/// still drawing system chrome: its sections come with their own radius and
/// their own inset, neither of which can be restyled, so a settings window kept
/// looking like a different application from the one it configures.
struct CardStack<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      // No `GlassEffectContainer` any more: it exists to let sibling glass
      // surfaces share one backdrop pass, and since `CardSurface` stopped
      // drawing glass in windows there is no glass here to group.
      VStack(alignment: .leading, spacing: Layout.loose) {
        content
      }
      .padding(Layout.loose)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Here rather than at each scene root. A card column is exactly the scope
      // the switch style belongs to, so a new settings page gets it by being a
      // card column — one fewer thing to remember than the modifier `Layout`'s
      // documentation already complains about having to remember.
      .toggleStyle(.morph)
    }
    // The window's field shows through: a scroll view of its own would paint
    // the system's background over it.
    .scrollContentBackground(.hidden)
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
  func cardSurface(
    accent: Color, radius: CGFloat = Layout.radiusCard, isRaised: Bool = false
  ) -> some View {
    modifier(CardSurface(accent: accent, radius: radius, isRaised: isRaised))
  }

  /// The plate the OSD and the identify overlay are drawn on.
  ///
  /// One modifier for both because the two had the same three lines in them,
  /// and because a style that has no material needs a *different modifier*
  /// rather than a different parameter — `.glassEffect` and `.background` are
  /// not interchangeable. That branch belongs in one place.
  func heroSurface() -> some View {
    modifier(HeroSurface())
  }
}

/// The overlay plate, with or without material.
///
/// These two surfaces are the exception the card rule is stated against: they
/// float over the desktop, so there is something behind them worth refracting
/// and glass earns its keep. Under a style that has no material there is no
/// such thing to sample, and the plate becomes an opaque one — which is the
/// same answer cards arrived at, for the same reason.
///
/// The rim matters more here than anywhere else in the app. `OverlayPanel`
/// draws no shadow and its window is clear, so on the flat plate the edge is
/// the *only* thing between the HUD and a busy wallpaper.
private struct HeroSurface: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    if theme.usesMaterial {
      // Tinted rather than plain glass. This is the surface the app is seen on
      // most often, and an untinted one is the app's own colour missing from
      // the only place it appears without being asked for.
      content.glassEffect(
        .regular.tint(theme.overlayTint), in: .rect(cornerRadius: Layout.radiusHero)
      )
    } else {
      let shape = RoundedRectangle(cornerRadius: Layout.radiusHero, style: .continuous)
      content
        .background { shape.fill(theme.surface) }
        .overlay { shape.strokeBorder(theme.rim(for: theme.tone), lineWidth: 1) }
    }
  }
}

/// The card background.
///
/// **No glass here, and that is the fix for a real bug.** These cards used to
/// draw `.regular` glass whenever they were in a window. Liquid Glass works by
/// refracting what is behind it, and behind a card in one of this app's windows
/// there was a flat window background and nothing else — so it rendered as an
/// even milky plate and the labels on it, most of them `.secondary`, became
/// genuinely unreadable. The file already warned that glass over glass goes
/// milky; glass over *nothing* does the same thing for the same reason.
///
/// So a card is now a solid surface from the theme, with the display's accent
/// washed over it. Glass is kept for the two overlays, which float over the
/// desktop and do have something to refract — and only under the styles that
/// draw material at all. Flat has none anywhere, and `HeroSurface` gives the
/// overlays an opaque plate for the same reason cards stopped drawing glass:
/// material with nothing to sample is not material, it is a milky wash.
///
/// Both depths keep the accent hairline, which is not decoration: it is how a
/// window showing two monitors stays legible at a glance rather than after
/// reading the headings.
private struct CardSurface: ViewModifier {
  let accent: Color
  let radius: CGFloat
  let isRaised: Bool

  @Environment(\.surfaceDepth) private var depth
  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
  }

  func body(content: Content) -> some View {
    content
      .background { surface }
      .overlay {
        shape.strokeBorder(theme.rim(for: accent).opacity(isRaised ? 1.6 : 1), lineWidth: 1)
      }
      // An effect, so it must not overshoot — a rim that rings reads as a
      // flicker rather than as the card noticing the pointer.
      .animation(motion.effectFast, value: isRaised)
      .shadow(
        color: theme.glow(for: accent, active: isRaised).opacity(0.55),
        radius: isRaised ? 14 : 0,
        y: isRaised ? 4 : 0
      )
      .animation(motion.effectDefault, value: isRaised)
  }

  @ViewBuilder
  private var surface: some View {
    let fill = depth == .onOpaque
      ? (isRaised ? theme.surfaceRaised : theme.surface)
      : theme.onGlassSurface

    shape
      .fill(fill)
      // The theme says what the app is; the wash says which display this card
      // belongs to. Two layers rather than one blended colour, so the accent
      // stays the same strength whichever theme is underneath it.
      .overlay { shape.fill(theme.wash(for: accent)) }
      .animation(motion.effectFast, value: isRaised)
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

/// A permission, granted or not.
///
/// Both states are always drawn, never only the bad one. A warning that appears
/// solely when something is missing leaves no way to tell "granted" apart from
/// "the app has not noticed yet" — which matters here more than usual, because
/// macOS ties these grants to the code signature and a stale entry from an
/// earlier build looks exactly like a working one.
///
/// The glyph swap is the point of the animation: coming back from System
/// Settings having just granted something, the confirmation should be
/// unmissable rather than a redraw you have to go looking for.
struct PermissionRow: View {
  let title: String
  let detail: String
  let isGranted: Bool
  let action: () -> Void

  @Environment(\.motion) private var motion

  var body: some View {
    StatusRow(
      symbol: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
      tint: isGranted ? Status.ok : Status.warn,
      title: title,
      detail: detail
    ) {
      if !isGranted {
        Button("Open Settings…", action: action)
          .buttonStyle(.soft(Status.warn))
          .font(TypeScale.detail.weight(.medium))
          .transition(.blurReplace)
      }
    }
    .animation(motion.spatialDefault, value: isGranted)
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
  var accent: Color?
  /// Set to let the figure be typed into as well as read.
  ///
  /// Optional rather than always on, because not every readout has anywhere to
  /// put a new value. The ones that do get a caret; the ones that do not stay
  /// a label, instead of inviting an edit that would go nowhere.
  var onCommit: ((Double) -> Void)?
  @ViewBuilder var content: Content

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        if let onCommit {
          EditableReadout(value: value, font: font, accent: accent, onCommit: onCommit)
            .foregroundStyle(theme.ink(for: accent ?? theme.tone))
        } else {
          Text("\(Int((value * 100).rounded()))%")
            .font(font)
            .foregroundStyle(theme.ink(for: accent ?? theme.tone))
            .contentTransition(.numericText(value: value))
            .animation(motion.effectFast, value: value)
        }
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
  @Environment(\.theme) private var theme

  var body: some View {
    Circle()
      .fill(theme.fill(for: accent))
      .frame(width: size, height: size)
      .overlay { ring }
      .shadow(color: theme.glow(for: accent, active: isReady), radius: 4)
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

/// An application's icon, found by bundle identifier.
///
/// Springs in on appearance rather than simply being there. A row that arrives
/// with its icon already placed reads as a table; one where the icon lands a
/// beat later reads as the app having been found.
///
/// Lives here rather than beside the app-rule list because dropping an app on
/// the menu bar icon needs the same picture, and an icon that arrives one way
/// in the settings and another way in the panel is two components pretending to
/// be one.
struct AppIcon: View {
  let bundleIdentifier: String
  var size: CGFloat = 26

  @Environment(\.motion) private var motion
  @State private var hasArrived = false

  var body: some View {
    Group {
      if let image = Self.icon(for: bundleIdentifier) {
        Image(nsImage: image)
          .resizable()
          .frame(width: size, height: size)
      } else {
        // The app has been moved or uninstalled. The rule is still valid — it
        // matches on the identifier — so this says "not found here" rather than
        // leaving a hole.
        Image(systemName: "questionmark.app.dashed")
          .font(.system(size: size * 0.7))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
      }
    }
    .scaleEffect(hasArrived ? 1 : 0.6)
    .opacity(hasArrived ? 1 : 0)
    .animation(motion.expressive, value: hasArrived)
    .onAppear { hasArrived = true }
  }

  private static func icon(for bundleIdentifier: String) -> NSImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }
}

/// The palette, as a row of swatches with one ring that travels.
///
/// Written twice before this — once for a display's accent override and once
/// for the app's theme — with the same `matchedGeometryEffect` and the same
/// comment explaining why the ring is shared. `SegmentedMorphPicker` already
/// says where the line is: the third copy is where a pattern becomes a
/// component.
///
/// `selection` is optional because the two callers mean different things by
/// "nothing": a display can fall back to the colour derived from its identity,
/// and the theme cannot. `allowsNone` is what separates them — with it off, a
/// tap on the current swatch does nothing rather than clearing it.
struct AccentSwatchPicker: View {
  @Binding var selection: Int?
  var allowsNone = true
  var accessibilityLabel: String

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Namespace private var ring
  @State private var hovered: Int?

  var body: some View {
    HStack(spacing: Layout.tight) {
      ForEach(Array(AccentPalette.tones.enumerated()), id: \.offset) { index, tone in
        swatch(index: index, tone: tone)
      }
    }
    .animation(motion.spatialDefault, value: selection)
    .animation(motion.spatialFast, value: hovered)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func swatch(index: Int, tone: Color) -> some View {
    let isSelected = selection == index

    return Circle()
      .fill(theme.fill(for: tone))
      .frame(width: 18, height: 18)
      .overlay {
        // One ring for the whole row, so choosing a colour makes it travel
        // there instead of blinking out here and in again over there.
        if isSelected {
          Circle()
            .strokeBorder(.primary, lineWidth: 2)
            .matchedGeometryEffect(id: "accentRing", in: ring)
        }
      }
      .scaleEffect(hovered == index ? 1.25 : 1)
      .onHover { hovering in
        hovered = hovering ? index : (hovered == index ? nil : hovered)
      }
      .onTapGesture {
        guard !isSelected || allowsNone else { return }
        selection = isSelected ? nil : index
        Haptics.detent()
      }
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var tone: Color { accent ?? theme.tone }

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
        return AnyShapeStyle(theme.fill(for: tone))
      }
      if configuration.isPressed {
        return AnyShapeStyle(tone.opacity(0.26))
      }
      return AnyShapeStyle(isHovered ? theme.wash(for: tone) : Color.primary.opacity(0.06))
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

extension View {
  /// A pulse of the display's own colour, running along a column of cards.
  ///
  /// For the moments when one action changes several displays at once — the
  /// master brightness slider, and applying a preset. The problem it solves is
  /// that those moments are invisible: the values update instantly and
  /// correctly, and nothing on screen says they belong to the same gesture.
  ///
  /// Crucially it is **light, not movement**. The obvious idea — animating the
  /// follower sliders so their handles glide into place — is unavailable and
  /// should stay that way: `ExpressiveSlider` pins `.animation(nil, value: x)`
  /// on its handle, because a handle that lags is a handle that is lying about
  /// where the display is. Any transaction opened above it would reach in and
  /// undo that. So the numbers jump, which is the truth, and the *cards* light
  /// up in sequence, which is the part worth staging.
  func accentWave(index: Int, trigger: Int, accent: Color) -> some View {
    modifier(AccentWave(index: index, trigger: trigger, accent: accent))
  }
}

private struct AccentWave: ViewModifier {
  let index: Int
  let trigger: Int
  let accent: Color

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  @ViewBuilder
  func body(content: Content) -> some View {
    if motion.isReduced {
      content
    } else {
      content.phaseAnimator([0, 1, 2], trigger: trigger) { view, phase in
        view
          .shadow(color: theme.glow(for: accent, active: phase == 1), radius: phase == 1 ? 18 : 0)
          .brightness(phase == 1 ? 0.045 : 0)
      } animation: { phase in
        switch phase {
        // The same capped-index arithmetic as `Entrance`, for the same reason:
        // past the eighth card the last one lights up late enough to look like
        // a hitch rather than a rhythm. Doubled, because a wave wants to be
        // read as travelling where an entrance only wants to feel unhurried.
        case 1: motion.effectFast.delay(Double(min(index, 8)) * motion.stagger * 2)
        case 2: .linear(duration: 0.01)
        default: motion.effectDefault
        }
      }
    }
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
