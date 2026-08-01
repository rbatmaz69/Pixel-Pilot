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

// MARK: - The recipe

/// How far a style pulls each surface away from the chosen colour.
///
/// The blend amounts used to be literals inside `AppTheme.init`, which was fine
/// while there was one answer. With three there would be thirty of them in one
/// function, and the file's whole argument is that the derivation is arithmetic
/// so it can be *checked* — thirty inline literals cannot be enumerated by a
/// test, and this can.
///
/// What is *not* in here is the point of it. There is no `CGFloat` and no
/// `Animation`, so a style cannot reach a corner radius or a spring even by
/// accident: `Layout` stays a set of plain statics and `Motion` is untouched.
/// A style is a colour-and-material decision, and the type says so.
///
/// Two flags one might expect are missing because a number already says it.
/// "No gradient" is `backdropTop == backdropBottom` — two identical stops
/// render as a flat fill, and the equality is directly assertable. "No lit
/// fills" is `lift == 0`, which collapses `fill(for:)` to a colour against
/// itself.
private struct ThemeRecipe: Equatable, Sendable {
  /// How much of the sink — black in the deep theme, white in the pale one —
  /// ends up in each surface. Higher is further from the colour.
  let backdropTop: Double
  let backdropBottom: Double
  let surface: Double
  let surfaceRaised: Double
  let onGlassSurface: Double
  /// How opaque the panel's card is over the material behind it.
  let onGlassOpacity: Double

  /// The accent's roles, at whatever strength this style asks for.
  let rimOpacity: Double
  let washOpacity: Double
  let glowOpacity: Double
  /// How far the top of a fill gradient is lifted toward white. Zero is a
  /// flat fill.
  let lift: Double

  /// The drifting wash behind the cards. Zero takes it out of the hierarchy.
  let ambientIntensity: Double

  /// Whether the two overlays and the menu bar panel draw real material.
  let usesMaterial: Bool
  /// The tint carried by the overlay plate, over the material or as the plate.
  let overlayTintOpacity: Double
  /// The theme's field over the menu bar panel's material. At 1 the material
  /// stops showing through at all, which is how Flat has no material without
  /// touching the window's structure.
  let panelTintOpacity: Double
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
  /// How much of those tones reaches the surface, and out of what.
  let style: ThemeStyle

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

  /// The strengths this theme's style asks for, kept for the roles below.
  private let recipe: ThemeRecipe

  /// - Parameter backdropTone: What the field is made of. `nil` follows the
  ///   accent, which is both the default and what the whole interface looked
  ///   like before the two could differ.
  /// - Parameter style: How much of those tones a surface carries. Defaulted,
  ///   and the default is the look the app shipped with — so every caller that
  ///   does not care about styles keeps the theme it always had.
  init(tone: Color, backdropTone: Color? = nil, isDark: Bool, style: ThemeStyle = .glass) {
    let field = backdropTone ?? tone
    let recipe = Self.recipe(for: style, isDark: isDark)
    self.tone = tone
    self.backdropTone = field
    self.isDark = isDark
    self.style = style
    self.recipe = recipe

    let sink: Color = isDark ? .black : .white

    // Each amount is a *target*, not a result. See `settled(_:resolvedBy:)`:
    // a style may ask for more colour than a particular tone can carry and
    // still leave room for legible type, and the answer to that is to give it
    // slightly less rather than to let the text fail.
    //
    // The light theme's amounts are inverted on purpose: there the field
    // carries more colour than the cards, so a card reads as lifted off it
    // rather than sunk into it. Doing it the other way round is what makes a
    // light interface look like a form.
    func settled(_ amount: Double, resolvedBy resolve: (Color) -> Color = { $0 }) -> Color {
      Self.settled(field, toward: sink, from: amount, isDark: isDark, resolvedBy: resolve)
    }

    backdropTop = settled(recipe.backdropTop)
    backdropBottom = settled(recipe.backdropBottom)
    surface = settled(recipe.surface)
    surfaceRaised = settled(recipe.surfaceRaised)

    // Resolved against what is actually behind it. A translucent card in the
    // menu bar panel is not the colour it is declared to be — the field shows
    // through the part the alpha leaves — and under a style that puts real
    // colour into both, the composite lands a good deal further from the sink
    // than the declared colour does. Clamping the declaration rather than the
    // composite would report success and hand back an unreadable card.
    let panelField = backdropTop
    let panelAlpha = recipe.onGlassOpacity
    onGlassSurface = settled(recipe.onGlassSurface) {
      $0.opacity(panelAlpha).over(panelField)
    }
    .opacity(panelAlpha)

    // The accent's, not the field's. Once the two can differ, the card's edge
    // is the largest thing left carrying the accent, and it is what keeps a
    // chosen accent visible against a field made of something else.
    rim = tone.opacity(recipe.rimOpacity)

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

  // MARK: The styles

  /// What each style asks for, at each end.
  ///
  /// The `.glass` rows are the amounts the app shipped with and must not move:
  /// choosing Glass is a promise that the interface looks exactly as it did
  /// before there was anything to choose, and `ThemeTests.glassIsUnchanged`
  /// holds the promise.
  ///
  /// The other four rows are bounded by arithmetic on one side and by taste on
  /// the other, and it is worth being clear which is which. The blends are
  /// arithmetic: see `settled(_:toward:from:isDark:resolvedBy:)` for the band a
  /// surface may not sit in. The opacities are taste — no test can decide them,
  /// so they are the numbers to reach for when a style looks wrong.
  private static func recipe(for style: ThemeStyle, isDark: Bool) -> ThemeRecipe {
    switch (style, isDark) {
    case (.glass, true):
      ThemeRecipe(
        backdropTop: 0.87, backdropBottom: 0.93,
        surface: 0.78, surfaceRaised: 0.72,
        onGlassSurface: 0.62, onGlassOpacity: 0.55,
        rimOpacity: 0.38, washOpacity: 0.12, glowOpacity: 0.45, lift: 0.30,
        ambientIntensity: 1.0,
        usesMaterial: true, overlayTintOpacity: 0.55, panelTintOpacity: 0.82
      )
    case (.glass, false):
      ThemeRecipe(
        backdropTop: 0.80, backdropBottom: 0.86,
        surface: 0.93, surfaceRaised: 0.96,
        onGlassSurface: 0.88, onGlassOpacity: 0.65,
        rimOpacity: 0.32, washOpacity: 0.12, glowOpacity: 0.45, lift: 0.30,
        ambientIntensity: 1.0,
        usesMaterial: true, overlayTintOpacity: 0.55, panelTintOpacity: 0.82
      )

    // Every surface pulled a long way back toward the tone. The material stays
    // — this is the loud style, not the flat one — but it has far less work to
    // do, because the colour is now in the surface rather than in a tint over
    // something borrowed from the desktop.
    case (.vivid, true):
      ThemeRecipe(
        backdropTop: 0.70, backdropBottom: 0.78,
        surface: 0.60, surfaceRaised: 0.53,
        onGlassSurface: 0.48, onGlassOpacity: 0.75,
        rimOpacity: 0.70, washOpacity: 0.20, glowOpacity: 0.60, lift: 0.30,
        ambientIntensity: 1.35,
        usesMaterial: true, overlayTintOpacity: 0.70, panelTintOpacity: 0.88
      )
    case (.vivid, false):
      ThemeRecipe(
        backdropTop: 0.58, backdropBottom: 0.66,
        surface: 0.74, surfaceRaised: 0.79,
        onGlassSurface: 0.68, onGlassOpacity: 0.80,
        rimOpacity: 0.60, washOpacity: 0.20, glowOpacity: 0.55, lift: 0.30,
        ambientIntensity: 1.35,
        usesMaterial: true, overlayTintOpacity: 0.70, panelTintOpacity: 0.88
      )

    // One flat field, no glow, no drift, and a rim doing the work depth used to
    // do. The two backdrop stops are equal, which is how the gradient goes
    // away without a flag to say so. Slightly more colour in the surfaces than
    // Glass has, because with no material and no gradient the flat colour is
    // the only thing left saying the app has one.
    case (.flat, true):
      ThemeRecipe(
        backdropTop: 0.88, backdropBottom: 0.88,
        // The panel's card is the window's card: with nothing translucent about
        // it, there is no reason for it to be a different colour, and matching
        // them means it separates from the panel exactly as well as a card
        // separates from a window.
        surface: 0.74, surfaceRaised: 0.68,
        onGlassSurface: 0.74, onGlassOpacity: 1.0,
        rimOpacity: 0.55, washOpacity: 0.07, glowOpacity: 0, lift: 0,
        ambientIntensity: 0,
        usesMaterial: false, overlayTintOpacity: 1.0, panelTintOpacity: 1.0
      )
    case (.flat, false):
      ThemeRecipe(
        backdropTop: 0.76, backdropBottom: 0.76,
        surface: 0.90, surfaceRaised: 0.94,
        onGlassSurface: 0.90, onGlassOpacity: 1.0,
        rimOpacity: 0.45, washOpacity: 0.07, glowOpacity: 0, lift: 0,
        ambientIntensity: 0,
        usesMaterial: false, overlayTintOpacity: 1.0, panelTintOpacity: 1.0
      )
    }
  }

  // MARK: The band

  /// The luminance a deep surface must not rise above.
  ///
  /// WCAG's ratio is `(L₁+0.05)/(L₂+0.05)`, so the best a surface of luminance
  /// `L` can ever offer is `max(1.05/(L+0.05), (L+0.05)/0.05)`. Body text is
  /// held to 7:1 against a card, and that needs `L ≤ 0.10` or `L ≥ 0.30` —
  /// **between those two figures 7:1 is arithmetically unreachable**, whatever
  /// colour the text is. `legible(on:ratio:)` would walk all the way to white,
  /// land near 4.6 and be right to.
  ///
  /// Glass leaves its dark surfaces around 0.02, so this never came up. A style
  /// whose job is to put more colour into a surface moves it straight toward
  /// that band, which is why the amounts in `recipe(for:isDark:)` are targets
  /// rather than results. The figure is below 0.10 rather than at it because
  /// `.secondary` is derived down from body text and inherits whatever slack is
  /// left here.
  private static let deepCeiling = 0.075

  /// The mirror. Here the binding constraint is not the text — 4.5:1 is
  /// reachable at every luminance — but `appearance`: a pale theme declares
  /// `.aqua`, and every system-drawn control resolves against that, so a field
  /// that dipped below 0.5 would have the scrollbars and the titlebar drawn for
  /// the wrong background.
  private static let paleFloor = 0.55

  /// `field` blended toward `sink`, or further if that is what it takes to land
  /// outside the band where the theme's own contrast floor cannot be met.
  ///
  /// The same move `legible(on:)` makes one screen up, for the same reason and
  /// with the same honesty: it is better to hand back slightly less colour than
  /// was asked for than to hand back a number that cannot be lived up to.
  ///
  /// The consequence is worth knowing rather than discovering: the palette's
  /// tones do not all have the same luminance, so **Vivid comes out a shade
  /// quieter in amber than it does in blue**. That is what "the same eight
  /// tones, mixed less" has to mean once the contrast is not negotiable. The
  /// alternative — a hand-tuned cap per tone — is eight numbers nobody would
  /// maintain, and it would break silently the first time a tone was retuned.
  ///
  /// - Parameter resolvedBy: Turns a candidate into the colour the eye actually
  ///   receives. The identity for an opaque surface; a composite for the one
  ///   that is translucent.
  private static func settled(
    _ field: Color,
    toward sink: Color,
    from amount: Double,
    isDark: Bool,
    resolvedBy resolve: (Color) -> Color = { $0 }
  ) -> Color {
    var blend = amount
    while blend < 1 {
      let candidate = field.blended(with: sink, by: blend)
      let luminance = resolve(candidate).relativeLuminance
      if isDark ? luminance <= deepCeiling : luminance >= paleFloor {
        return candidate
      }
      blend += 0.01
    }
    // Unreachable: black is at zero and white is at one, so the loop above
    // always finds an answer before it runs out of room.
    return sink
  }

  // MARK: The accent's roles

  /// A card's tint, at the strength this style asks for.
  ///
  /// These four used to be plain `Color` extensions, which meant they could not
  /// see the theme and so could not see the style. They are methods here for
  /// the same reason `ink(for:)` is: the accent is one hue playing several
  /// parts, and only the theme knows how loudly this interface is meant to
  /// speak.
  func wash(for accent: Color) -> Color { accent.opacity(recipe.washOpacity) }

  /// The hairline around a tinted surface. Under Flat this is most of what
  /// tells a card from the field, because there is no material and no shadow
  /// left to do it.
  func rim(for accent: Color) -> Color { accent.opacity(recipe.rimOpacity) }

  /// The glow under an active control. Used at zero opacity when inactive, so
  /// the shadow can be animated rather than inserted — and at zero always under
  /// a style that has no glow.
  func glow(for accent: Color, active: Bool) -> Color {
    accent.opacity(active ? recipe.glowOpacity : 0)
  }

  /// The accent lifted toward white, for the top of a fill or a highlight.
  func lifted(_ accent: Color) -> Color { accent.mix(with: .white, by: recipe.lift) }

  /// The fill for tracks, handles and progress. Top-lit, the way a physical
  /// control would be — except under a style with no lift, where the two stops
  /// are the same colour and it renders flat.
  func fill(for accent: Color) -> LinearGradient {
    LinearGradient(
      colors: [lifted(accent), accent], startPoint: .top, endPoint: .bottom
    )
  }

  /// What the OSD and the identify overlay are made of: a tint over real glass
  /// where there is material, and the plate itself where there is not.
  var overlayTint: Color { surface.opacity(recipe.overlayTintOpacity) }

  /// Whether the two overlays and the menu bar panel draw material at all.
  var usesMaterial: Bool { recipe.usesMaterial }

  /// The theme's field over the menu bar panel's material. At 1 nothing of the
  /// desktop survives, which is how Flat has no material there.
  var panelTintOpacity: Double { recipe.panelTintOpacity }

  /// How strongly the drifting wash behind the cards is drawn. Zero means it is
  /// not drawn at all — and, in `AmbientBackdrop`, not animated either.
  var ambientIntensity: Double { recipe.ambientIntensity }

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

  /// How much of those colours reaches the surface, and out of what.
  var style: ThemeStyle {
    didSet {
      guard style != oldValue else { return }
      Preferences.shared.updateGlobal { $0.themeStyle = style }
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
    let style = stored.themeStyle
    let systemIsDark = NSApplication.shared.effectiveAppearance
      .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    // Assigning a property inside `init` does not run its `didSet`, so none of
    // these writes back to `Preferences` on the way in — which is what makes
    // this shape safe to repeat for each new setting.
    toneIndex = tone
    backdropToneIndex = field
    self.mode = mode
    self.style = style
    self.systemIsDark = systemIsDark
    theme = Self.build(
      tone: tone, field: field, mode: mode, style: style, systemIsDark: systemIsDark
    )
  }

  private func rebuild() {
    theme = Self.build(
      tone: toneIndex, field: backdropToneIndex, mode: mode, style: style,
      systemIsDark: systemIsDark
    )
  }

  private static func build(
    tone: Int, field: Int?, mode: ThemeMode, style: ThemeStyle, systemIsDark: Bool
  ) -> AppTheme {
    let isDark: Bool = switch mode {
    case .system: systemIsDark
    case .light: false
    case .dark: true
    }
    return AppTheme(
      tone: AccentPalette.tones[tone],
      backdropTone: field.map { AccentPalette.tones[$0] },
      isDark: isDark,
      style: style
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
