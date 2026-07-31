import AppKit
import PixelPilotCore
import SwiftUI

// The app's colour, as opposed to each display's colour.
//
// `AccentPalette` answers "which monitor is this?" — eight tones, derived from
// a `DisplayKey`, and they have to stay distinguishable from one another. This
// file answers something else: what colour is the *application*. One tone,
// chosen deliberately, and every surface is built out of it — the window field,
// the cards, the menu bar panel, the HUD.
//
// The rule the whole file exists to keep: **no surface is grey.** "Light" is a
// pale wash of the chosen colour and "dark" is a deep one; neither is white and
// neither is black. What must not follow from that is unreadable text, so the
// derivation is arithmetic rather than taste, and `ThemeTests` holds every tone
// in both modes to a contrast ratio.

// MARK: - Colour arithmetic

extension Color {
  /// The colour in sRGB, or mid grey if it cannot be resolved.
  ///
  /// `Color.mix(with:by:)` would be the shorter road, but it interpolates
  /// perceptually and hands back something that cannot be reasoned about
  /// numerically. Every value here has to be checkable against a contrast
  /// ratio, so the mixing is done in sRGB by hand.
  var srgb: (red: Double, green: Double, blue: Double, alpha: Double) {
    guard let resolved = NSColor(self).usingColorSpace(.sRGB) else {
      return (0.5, 0.5, 0.5, 1)
    }
    return (
      Double(resolved.redComponent),
      Double(resolved.greenComponent),
      Double(resolved.blueComponent),
      Double(resolved.alphaComponent)
    )
  }

  /// WCAG relative luminance, for deciding whether text should be light or dark
  /// and for proving that it is legible once decided.
  var relativeLuminance: Double {
    let components = srgb
    func linear(_ channel: Double) -> Double {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(components.red)
      + 0.7152 * linear(components.green)
      + 0.0722 * linear(components.blue)
  }

  /// WCAG contrast ratio, 1 (identical) to 21 (black on white).
  func contrastRatio(to other: Color) -> Double {
    let a = relativeLuminance
    let b = other.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// A straight sRGB mix. `amount` is how much of `other` ends up in the result.
  func blended(with other: Color, by amount: Double) -> Color {
    let t = min(max(amount, 0), 1)
    let a = srgb
    let b = other.srgb
    return Color(
      .sRGB,
      red: a.red + (b.red - a.red) * t,
      green: a.green + (b.green - a.green) * t,
      blue: a.blue + (b.blue - a.blue) * t,
      opacity: a.alpha + (b.alpha - a.alpha) * t
    )
  }

  /// This colour composited over an opaque one, so a translucent value can be
  /// held to a contrast ratio against what is actually behind it.
  func over(_ background: Color) -> Color {
    let top = srgb
    return background.blended(with: opacity(1), by: top.alpha)
  }

  /// Pulls the colour toward white or black until it is readable on
  /// `background`, and no further.
  ///
  /// The point is to keep as much of the hue as the ratio allows: a themed
  /// interface whose text is plain white has thrown away the reason it was
  /// tinted, and one whose text is merely nearly-legible has thrown away
  /// something worse.
  func legible(on background: Color, ratio: Double = 4.5) -> Color {
    guard contrastRatio(to: background) < ratio else { return self }

    // Away from the background is the obvious direction and not always the
    // right one. A background of middling luminance cannot reach a high ratio
    // by going lighter at all — pure white against it tops out below 4.5 — and
    // walking that way would hand back something still unreadable while
    // reporting success. So the direction is whichever one can get there,
    // preferring the obvious one when both can.
    let preferred: Color = background.relativeLuminance < 0.5 ? .white : .black
    let target: Color = preferred.contrastRatio(to: background) >= ratio
      ? preferred
      : (preferred == .white ? .black : .white)

    var amount = 0.05
    while amount < 1 {
      let candidate = blended(with: target, by: amount)
      if candidate.contrastRatio(to: background) >= ratio { return candidate }
      amount += 0.05
    }
    return target
  }
}

// MARK: - The theme

/// Every surface colour in the app, derived from two tones.
///
/// Two rather than one because they answer different questions. The accent is
/// what a control is *at full strength* — a filled track, a switch that is on,
/// the ring around a chosen swatch — and it wants to be vivid. The field is
/// several hundred square points of wall behind everything else, and a colour
/// that is right for a 42 pt switch is rarely right for that. Tying them
/// together means one of the two is always a compromise, so they are separate,
/// and the field simply follows the accent until it is told otherwise.
///
/// Stored rather than computed, because resolving a `Color` to components goes
/// through `NSColor` and a view body must not pay for that on every pass —
/// which is also why `ThemeStore` holds one of these rather than making a new
/// one per access.
struct AppTheme: Equatable, Sendable {
  /// The accent, undiluted. Sliders, switches, rings and glows use this; it is
  /// the one place the theme is at full strength.
  let tone: Color
  /// What the field and the cards are made of. Equal to `tone` unless a
  /// separate background colour has been chosen.
  let backdropTone: Color
  /// Whether this is the deep end of those tones or the pale one.
  let isDark: Bool

  /// The window field. Two stops, lighter at the top, the way a lit surface is.
  let backdropTop: Color
  let backdropBottom: Color

  /// A card standing on the field, and the same card under the pointer.
  let surface: Color
  let surfaceRaised: Color

  /// A card inside the menu bar panel, where there is real material behind it
  /// and the fill has to let some of it through.
  let onGlassSurface: Color

  /// The card's edge. Carries the tone at close to full strength — it is the
  /// only line in a card that says which colour the app is set to.
  let rim: Color

  /// Body text, and the tinted near-white or near-black it resolves to.
  let primaryText: Color

  /// Each palette tone as type, already checked against `surface`.
  ///
  /// Worked out here, once, rather than at the call site. `legible(on:)` walks
  /// a loop of `NSColor` conversions, and the readouts that need it are redrawn
  /// on every frame of a slider drag — which is exactly the kind of cost this
  /// app is built to refuse. Eight entries covers every accent that can appear,
  /// because the palette is what accents come from.
  private let paletteInk: [Color]

  /// - Parameter backdropTone: What the field is made of. `nil` follows the
  ///   accent, which is both the default and what the whole interface looked
  ///   like before the two could differ.
  init(tone: Color, backdropTone: Color? = nil, isDark: Bool) {
    let field = backdropTone ?? tone
    self.tone = tone
    self.backdropTone = field
    self.isDark = isDark

    let sink: Color = isDark ? .black : .white

    if isDark {
      backdropTop = field.blended(with: sink, by: 0.87)
      backdropBottom = field.blended(with: sink, by: 0.93)
      surface = field.blended(with: sink, by: 0.78)
      surfaceRaised = field.blended(with: sink, by: 0.72)
      onGlassSurface = field.blended(with: sink, by: 0.62).opacity(0.55)
    } else {
      // Inverted on purpose: in the pale theme the field carries more colour
      // than the cards, so a card reads as lifted off it rather than sunk into
      // it. Doing it the other way round is what makes a light interface look
      // like a form.
      backdropTop = field.blended(with: sink, by: 0.80)
      backdropBottom = field.blended(with: sink, by: 0.86)
      surface = field.blended(with: sink, by: 0.93)
      surfaceRaised = field.blended(with: sink, by: 0.96)
      onGlassSurface = field.blended(with: sink, by: 0.88).opacity(0.65)
    }

    // The accent's, not the field's. Once the two can differ, the card's edge
    // is the largest thing left carrying the accent, and it is what keeps a
    // chosen accent visible against a field made of something else.
    rim = tone.opacity(isDark ? 0.38 : 0.32)

    // Tinted with the field rather than the accent, so body copy belongs to the
    // surface it sits on, then held to 7:1 — the stricter of the two WCAG
    // thresholds, because this is the level `.secondary` and `.tertiary` are
    // derived down from and they inherit whatever slack is left here.
    let ink: Color = isDark
      ? field.blended(with: .white, by: 0.88)
      : field.blended(with: .black, by: 0.86)
    primaryText = ink.legible(on: surface, ratio: 7)

    let cardSurface = surface
    paletteInk = AccentPalette.tones.map {
      $0.accentText(isDark: isDark).legible(on: cardSurface, ratio: 4.5)
    }
  }

  /// An accent set as type on one of this theme's cards.
  ///
  /// The palette is tuned for fills, and a fill colour is not a text colour.
  /// That was already true when one tone drove everything; with the field
  /// chosen separately it is sharper — amber type on a pale amber card is a
  /// different problem from amber type on a deep teal one, and only the theme
  /// knows which card it is.
  func ink(for accent: Color) -> Color {
    if let index = AccentPalette.tones.firstIndex(of: accent) {
      return paletteInk[index]
    }
    // A status colour or something else off-palette. Not worth a `legible`
    // walk in a view body, and these are chosen for meaning rather than to fit
    // a theme in the first place.
    return accent.accentText(isDark: isDark)
  }

  /// The system appearance that agrees with this theme.
  ///
  /// This is the load-bearing line of the whole file. Setting it on a window
  /// makes `.secondary`, `.tertiary`, `.quaternary`, `Divider`, the scrollbars
  /// and the titlebar text resolve against a surface of the right lightness —
  /// so the coloured field does not have to be paid for with a hand-written
  /// colour at every label in the app.
  var appearance: NSAppearance? {
    NSAppearance(named: isDark ? .darkAqua : .aqua)
  }

  /// The window field as a gradient, for `withAppTheme()` and anything else
  /// that needs to continue it.
  var backdrop: LinearGradient {
    LinearGradient(
      colors: [backdropTop, backdropBottom], startPoint: .top, endPoint: .bottom
    )
  }

  /// Used only as the environment's default, for previews and for any view
  /// rendered outside a themed root.
  static let fallback = AppTheme(tone: AccentPalette.tones[0], isDark: true)
}

// MARK: - The store

/// The chosen theme, and the one place it is written down.
///
/// A shared instance for the same reason `Preferences.shared` is one: the
/// windows, the menu bar panel, the HUD and the identify overlay are built by
/// four unrelated controllers, and threading a theme through all of them would
/// mean every one of them holding a reference to something that only ever has
/// one value.
@MainActor
@Observable
final class ThemeStore {
  static let shared = ThemeStore()

  /// The accent, as an index into the palette.
  var toneIndex: Int {
    didSet {
      guard toneIndex != oldValue else { return }
      Preferences.shared.updateGlobal { $0.themeToneIndex = toneIndex }
      rebuild()
    }
  }

  /// The field, as an index into the same palette. `nil` follows the accent.
  var backdropToneIndex: Int? {
    didSet {
      guard backdropToneIndex != oldValue else { return }
      Preferences.shared.updateGlobal { $0.themeBackdropToneIndex = backdropToneIndex }
      rebuild()
    }
  }

  var mode: ThemeMode {
    didSet {
      guard mode != oldValue else { return }
      Preferences.shared.updateGlobal { $0.themeMode = mode }
      rebuild()
    }
  }

  /// Kept current by `AppModel`, which already observes the effective
  /// appearance for the preset bindings.
  var systemIsDark: Bool {
    didSet {
      guard systemIsDark != oldValue, mode == .system else { return }
      rebuild()
    }
  }

  /// Stored, not computed. Building one resolves a few dozen colours through
  /// `NSColor`, and this is read by every themed view on every pass — so it is
  /// worked out when something changes and not once per read.
  private(set) var theme: AppTheme

  init() {
    let stored = Preferences.shared.global
    let indices = AccentPalette.tones.indices
    // Locals first, then the stored properties: `theme` is derived from the
    // other four, and a derived property cannot read them until every one of
    // them has been assigned.
    let tone = indices.contains(stored.themeToneIndex) ? stored.themeToneIndex : 0
    let field = stored.themeBackdropToneIndex.flatMap { indices.contains($0) ? $0 : nil }
    let mode = stored.themeMode
    let systemIsDark = NSApplication.shared.effectiveAppearance
      .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    toneIndex = tone
    backdropToneIndex = field
    self.mode = mode
    self.systemIsDark = systemIsDark
    theme = Self.build(tone: tone, field: field, mode: mode, systemIsDark: systemIsDark)
  }

  private func rebuild() {
    theme = Self.build(
      tone: toneIndex, field: backdropToneIndex, mode: mode, systemIsDark: systemIsDark
    )
  }

  private static func build(
    tone: Int, field: Int?, mode: ThemeMode, systemIsDark: Bool
  ) -> AppTheme {
    let isDark: Bool = switch mode {
    case .system: systemIsDark
    case .light: false
    case .dark: true
    }
    return AppTheme(
      tone: AccentPalette.tones[tone],
      backdropTone: field.map { AccentPalette.tones[$0] },
      isDark: isDark
    )
  }
}

// MARK: - Distribution

extension EnvironmentValues {
  /// Injected by `withAppTheme()` at the root of every window, panel and
  /// overlay — the same arrangement as `\.motion`.
  @Entry var theme: AppTheme = .fallback
}

extension View {
  /// Puts the current theme in the environment and paints the surface it
  /// describes.
  ///
  /// `paintsWindow` is false for the menu bar panel and the two overlays. They
  /// are not rectangles of their own — their field is painted by a panel that
  /// is deliberately clear and round-cornered — so both the backdrop and the
  /// window colouring would show up as a square behind the corners.
  func withAppTheme(paintsWindow: Bool = true) -> some View {
    modifier(ThemeResolver(paintsWindow: paintsWindow))
  }
}

private struct ThemeResolver: ViewModifier {
  let paintsWindow: Bool

  func body(content: Content) -> some View {
    // Read from the shared store rather than passed in, so a change in the
    // settings window repaints every open surface: this body re-evaluates and
    // the environment value under it goes with it.
    let theme = ThemeStore.shared.theme

    return content
      .environment(\.theme, theme)
      .tint(theme.tone)
      // Set as the primary level rather than on each label: `.secondary` and
      // `.tertiary` are derived from whatever primary is, so one call keeps the
      // whole hierarchy on the theme's ink instead of the system's.
      .foregroundStyle(theme.primaryText)
      .background {
        if paintsWindow {
          theme.backdrop.ignoresSafeArea()
        }
      }
      .background {
        if paintsWindow {
          ThemedWindowChrome(theme: theme)
        }
      }
  }
}

/// Teaches the containing `NSWindow` what colour it is.
///
/// Three things AppKit owns and SwiftUI cannot reach: the appearance every
/// system-drawn control resolves against, the colour behind the content, and
/// the titlebar — which would otherwise sit above a coloured field as a grey
/// strip, the one seam that would give the whole thing away.
private struct ThemedWindowChrome: NSViewRepresentable {
  let theme: AppTheme

  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.theme = theme
    return view
  }

  func updateNSView(_ view: ChromeView, context: Context) {
    view.theme = theme
  }

  /// A view rather than a one-shot call, because there is no moment at which
  /// both facts are known from outside: the theme arrives when SwiftUI updates,
  /// and the window arrives when AppKit attaches the hierarchy, in either
  /// order.
  final class ChromeView: NSView {
    var theme: AppTheme? {
      didSet { if theme != oldValue { apply() } }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    private func apply() {
      guard let window, let theme else { return }
      window.appearance = theme.appearance
      window.backgroundColor = NSColor(theme.backdropBottom)
      if window.styleMask.contains(.titled) {
        window.titlebarAppearsTransparent = true
      }
    }
  }
}
