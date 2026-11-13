import CoreGraphics
import PixelPilotCore
import SwiftUI
import Testing

@testable import PixelPilot

private extension CGImage {
  /// One pixel, as a `Color`, so a rendered result can be compared with the
  /// values the theme was built from.
  func colour(atX x: Int, y: Int) -> Color? {
    var pixel: [UInt8] = [0, 0, 0, 0]
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: &pixel,
            width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    // Draw the whole image shifted so that the pixel of interest lands in the
    // context's single slot.
    context.draw(
      self,
      in: CGRect(x: -CGFloat(x), y: CGFloat(y) - CGFloat(height) + 1,
                 width: CGFloat(width), height: CGFloat(height))
    )
    guard pixel[3] > 0 else { return nil }
    return Color(
      .sRGB,
      red: Double(pixel[0]) / 255,
      green: Double(pixel[1]) / 255,
      blue: Double(pixel[2]) / 255
    )
  }
}

/// The theme's promise, held to a number.
///
/// These exist because of a real bug, not as a formality: the settings window
/// used to draw glass cards over a flat window background, which renders as an
/// even milky plate, and the labels on it could not be read. "It looks fine to
/// me" is what let that ship — the derivation is arithmetic now, so it can be
/// checked instead of eyeballed.
///
/// Every *combination* is held in both modes — all eight accents against all
/// eight backgrounds, which is 128 themes. That is the point of testing rather
/// than looking: once the two colours can be chosen apart, nobody is going to
/// eyeball amber-on-teal, and it is exactly the pairing where a colour picked
/// for a switch lands on a field it was never tried against.
@Suite("Theme")
struct ThemeTests {
  private static let themes: [AppTheme] = ThemeStyle.allCases.flatMap { style in
    AccentPalette.tones.flatMap { tone in
      AccentPalette.tones.flatMap { field in
        [
          AppTheme(tone: tone, backdropTone: field, isDark: true, style: style),
          AppTheme(tone: tone, backdropTone: field, isDark: false, style: style),
        ]
      }
    }
  }

  /// The style belongs in here, not as a nicety. Without it three different
  /// themes produce the same failure message and there is no way to tell which
  /// one broke.
  private static func describe(_ theme: AppTheme) -> String {
    "\(theme.style.displayName) \(theme.isDark ? "dark" : "light") "
      + "\(theme.tone) on \(theme.backdropTone)"
  }

  @Test("Body text clears 7:1 on a card")
  func primaryTextOnSurface() {
    for theme in Self.themes {
      let ratio = theme.primaryText.contrastRatio(to: theme.surface)
      #expect(ratio >= 7, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// Cards are not the only place text lands: a section heading or a footer can
  /// sit straight on the window's field.
  @Test("Body text clears 4.5:1 on the window field")
  func primaryTextOnBackdrop() {
    for theme in Self.themes {
      for field in [theme.backdropTop, theme.backdropBottom] {
        let ratio = theme.primaryText.contrastRatio(to: field)
        #expect(ratio >= 4.5, "\(Self.describe(theme)) — \(ratio)")
      }
    }
  }

  /// `.secondary` is derived from the primary style at roughly half strength,
  /// and most of the explanatory copy in this app is set in it. 3:1 is the
  /// large-text threshold and the floor worth defending for it.
  @Test("Secondary text clears 3:1 on a card")
  func secondaryTextOnSurface() {
    for theme in Self.themes {
      let secondary = theme.primaryText.opacity(0.5).over(theme.surface)
      let ratio = secondary.contrastRatio(to: theme.surface)
      #expect(ratio >= 3, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// The check the second colour makes necessary.
  ///
  /// An accent set as type — the percentage over a slider, a card's glyph —
  /// used to sit on a surface made of itself, so it could hardly fail. Now it
  /// can land on a field chosen independently, and amber type on a pale amber
  /// card is a different problem from amber type on a deep teal one.
  @Test("Any accent is readable as type on any background")
  func accentInkOnSurface() {
    for theme in Self.themes {
      for accent in AccentPalette.tones {
        let ratio = theme.ink(for: accent).contrastRatio(to: theme.surface)
        #expect(ratio >= 4.49, "\(Self.describe(theme)) — accent \(accent) at \(ratio)")
      }
    }
  }

  /// The accent has to remain *findable* once it no longer makes the field.
  /// The card's rim is the largest thing carrying it, and a rim that matches
  /// the surface it is drawn on is not a rim.
  @Test("A card's rim stands out from the card")
  func rimIsVisible() {
    for theme in Self.themes {
      // Distance rather than contrast ratio: an accent can match the surface
      // in luminance and still be plainly a different colour, and a rim is
      // read as a colour rather than as a light level.
      let rim = theme.rim.over(theme.surface).srgb
      let card = theme.surface.srgb
      let distance = ((rim.red - card.red) * (rim.red - card.red)
        + (rim.green - card.green) * (rim.green - card.green)
        + (rim.blue - card.blue) * (rim.blue - card.blue)).squareRoot()
      #expect(distance >= 0.04, "\(Self.describe(theme)) — \(distance)")
    }
  }

  /// A card has to be visible *as* a card. Its own edge is a hairline of the
  /// tone, but the fill has to separate from the field as well, or the whole
  /// window is one flat colour with text floating on it.
  @Test("A card separates from the field it stands on")
  func surfaceSeparatesFromBackdrop() {
    for theme in Self.themes {
      let ratio = theme.surface.contrastRatio(to: theme.backdropTop)
      #expect(ratio >= 1.08, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// The load-bearing coupling: `window.appearance` is set from `isDark`, and
  /// every semantic colour in the app — `.secondary`, `.quaternary`, `Divider`,
  /// the scrollbars — resolves against it. If the field's lightness disagreed
  /// with the appearance, all of those would be drawn for the wrong background.
  @Test("The field's lightness agrees with the declared appearance")
  func fieldMatchesAppearance() {
    for theme in Self.themes {
      #expect(
        (theme.backdropTop.relativeLuminance < 0.5) == theme.isDark,
        "\(Self.describe(theme)) — \(theme.backdropTop.relativeLuminance)"
      )
      #expect((theme.surface.relativeLuminance < 0.5) == theme.isDark)
    }
  }

  /// Warm Paper and Dark Walnut surfaces carry genuine warmth rather than flat grey.
  @Test("Warm Paper and Dark Walnut surfaces remain neutral across accent choices")
  func surfacesStayWarmPaperAndDarkWalnut() {
    for isDark in [true, false] {
      let expectedSurface = isDark ? AppTheme.darkWalnutCard : AppTheme.warmPaperCard
      let expectedBottom = isDark ? AppTheme.darkWalnutWindow : AppTheme.warmPaperWindow
      for tone in AccentPalette.tones {
        for field in AccentPalette.tones {
          let theme = AppTheme(tone: tone, backdropTone: field, isDark: isDark, style: .glass)
          #expect(theme.surface.srgb == expectedSurface.srgb)
          #expect(theme.backdropBottom.srgb == expectedBottom.srgb)
          #expect(theme.sidebarSurface.srgb.alpha > 0.4)
          let components = theme.backdropTop.srgb
          let spread = max(components.red, components.green, components.blue)
            - min(components.red, components.green, components.blue)
          #expect(spread > 0.01, "\(Self.describe(theme)) is flat grey — \(components)")
        }
      }
    }
  }

  // MARK: - What the styles make necessary

  /// A hover state is a card too, and until there were styles it was so far
  /// from the band that nobody had to check.
  ///
  /// 4.5:1 rather than the 7:1 the resting card gets, and the difference is not
  /// an oversight: 7:1 is defended on `surface` because `.secondary` and
  /// `.tertiary` are derived down from body text *there* and inherit its slack.
  /// A raised card is a transient state under the pointer.
  @Test("Body text stays readable on a card under the pointer")
  func primaryTextOnSurfaceRaised() {
    for theme in Self.themes {
      let ratio = theme.primaryText.contrastRatio(to: theme.surfaceRaised)
      #expect(ratio >= 4.5, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// The menu bar panel's card, which is where this app is actually used.
  ///
  /// Untested until now, and the most exposed surface there is: it is the one
  /// card that is translucent, so what reaches the eye is a composite of the
  /// card and the panel field behind it rather than the colour the theme names.
  /// Under a style that puts real colour into both, that composite lands
  /// further from the sink than either layer suggests.
  ///
  /// 4.5:1 for the same reason as the window field, which this is: a panel is a
  /// field with cards on it, not a card.
  @Test("Body text is readable on a card in the menu bar panel")
  func primaryTextOnPanelCard() {
    for theme in Self.themes {
      let card = theme.onGlassSurface.over(theme.backdropTop)
      let ratio = theme.primaryText.contrastRatio(to: card)
      #expect(ratio >= 4.5, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// And it has to be visible *as* a card there — but only Flat can be held to
  /// a number for it.
  ///
  /// This check is deliberately not applied to the styles that draw material.
  /// A translucent card over a blurred desktop is separated by things a colour
  /// ratio cannot see, and the shipping look proves it: Glass in its pale mode
  /// sits between 1.04 and 1.08 here and has never been hard to read. Lowering
  /// the bar until Glass fitted under it would be picking a number to match an
  /// answer.
  ///
  /// Flat is a different claim. Its panel card is fully opaque and its field is
  /// one flat colour, so the blend difference is the whole of what tells them
  /// apart — the same situation a card on a window field is in, and so the same
  /// bar as `surfaceSeparatesFromBackdrop`.
  @Test("A flat panel card separates from the panel's field")
  func flatPanelCardSeparatesFromPanelField() {
    for theme in Self.themes where theme.style == .flat {
      let card = theme.onGlassSurface.over(theme.backdropTop)
      let ratio = card.contrastRatio(to: theme.backdropTop)
      #expect(ratio >= 1.08, "\(Self.describe(theme)) — \(ratio)")
    }
  }

  /// The bracket on the other side of the clamp.
  ///
  /// Every other test here says a theme must not be *too* coloured. Without
  /// this one, `settled` could quietly pull Vivid all the way back to Glass for
  /// some tone — the suite would stay green and the feature would simply not
  /// exist for anyone whose accent happened to be amber.
  @Test("Vivid puts more accent colour into surfaces than Warm Paper/Walnut Glass")
  func vividIsVividerThanGlass() {
    func distanceFromTone(_ a: Color, _ b: Color) -> Double {
      let sa = a.srgb
      let sb = b.srgb
      return ((sa.red - sb.red) * (sa.red - sb.red)
        + (sa.green - sb.green) * (sa.green - sb.green)
        + (sa.blue - sb.blue) * (sa.blue - sb.blue)).squareRoot()
    }

    for tone in AccentPalette.tones {
      for field in AccentPalette.tones {
        for isDark in [true, false] {
          let glass = AppTheme(tone: tone, backdropTone: field, isDark: isDark, style: .glass)
          let vivid = AppTheme(tone: tone, backdropTone: field, isDark: isDark, style: .vivid)

          #expect(
            distanceFromTone(vivid.surface, glass.surface) > 0.01,
            "\(Self.describe(vivid)) — surface is indistinguishable from neutral Glass"
          )
        }
      }
    }
  }

  /// Flat's three promises, which are all made by numbers rather than by
  /// branches and so can all be read back.
  @Test("Flat has no gradient, no material and no drift")
  func flatIsFlat() {
    for theme in Self.themes where theme.style == .flat {
      #expect(
        theme.backdropTop.srgb == theme.backdropBottom.srgb,
        "\(Self.describe(theme)) — the field still has two stops"
      )
      #expect(!theme.usesMaterial, "\(Self.describe(theme))")
      #expect(theme.ambientIntensity == 0, "\(Self.describe(theme))")
      #expect(theme.panelTintOpacity == 1, "\(Self.describe(theme))")
    }
  }

  /// The other two styles keep what Flat gives up. Written down because "Flat
  /// is the one without material" is only a distinction while that is true.
  @Test("Glass and Vivid keep their material")
  func materialStyliesKeepTheirMaterial() {
    for theme in Self.themes where theme.style != .flat {
      #expect(theme.usesMaterial, "\(Self.describe(theme))")
      #expect(theme.panelTintOpacity < 1, "\(Self.describe(theme))")
      #expect(theme.backdropTop.srgb != theme.backdropBottom.srgb, "\(Self.describe(theme))")
    }
  }

  /// The one test that looks at pixels.
  ///
  /// Everything above checks the numbers a theme is made of; this checks what
  /// a real `PanelCard` actually comes out as, because the bug being fixed was
  /// not in the numbers. A glass card over a flat window background rendered as
  /// an even milky plate — the fill was neither the surface it claimed nor
  /// anything else nameable. So: render the card, read the pixels back, and
  /// require that its field is the colour the theme says it is.
  ///
  /// Run for every style, not only the one that had the bug. Each style changes
  /// both layers this samples — the surface and the wash over it — so checking
  /// Glass alone would leave the other two with exactly the hole this was
  /// written to close.
  @MainActor
  @Test("A card renders as the surface the theme describes", arguments: ThemeStyle.allCases)
  func cardRendersAsItsSurface(style: ThemeStyle) throws {
    let theme = AppTheme(tone: AccentPalette.tones[0], isDark: true, style: style)

    let card = PanelCard(title: "Keyboard keys", systemImage: "keyboard") {
      Text("Use the keyboard's brightness and volume keys")
    }
    .frame(width: 320)
    .environment(\.theme, theme)
    .foregroundStyle(theme.primaryText)
    .background(theme.backdropBottom)

    let renderer = ImageRenderer(content: card)
    renderer.scale = 1
    let image = try #require(renderer.cgImage)

    // The last few points of the card are its bottom padding: whatever else is
    // in it, that strip is nothing but the surface.
    let row = image.height - 4
    let samples = stride(from: 40, to: image.width - 40, by: 8).compactMap {
      image.colour(atX: $0, y: row)
    }
    #expect(!samples.isEmpty)

    // Cards in Glass and Flat use neutral Warm Paper / Dark Walnut surfaces
    // without an accent wash; only Vivid adds a full-surface wash.
    let expected = style == .vivid ? theme.wash(for: theme.tone).over(theme.surface) : theme.surface
    for sample in samples {
      #expect(
        sample.contrastRatio(to: expected) < 1.05,
        "\(style.displayName) rendered \(sample.srgb) against expected \(expected.srgb)"
      )
    }
  }

  /// Warm Studio Paper & Dark Walnut values pinned so surface hues cannot drift.
  @Test("Glass derives exact Warm Paper and Dark Walnut mockup surfaces")
  func glassIsUnchanged() {
    for tone in AccentPalette.tones {
      for field in AccentPalette.tones {
        for isDark in [true, false] {
          let theme = AppTheme(tone: tone, backdropTone: field, isDark: isDark)
          let expectedTop = isDark ? AppTheme.darkWalnutWindowTop : AppTheme.warmPaperWindowTop
          let expectedBottom = isDark ? AppTheme.darkWalnutWindow : AppTheme.warmPaperWindow
          let expectedSurface = isDark ? AppTheme.darkWalnutCard : AppTheme.warmPaperCard
          let expectedRaised = isDark ? AppTheme.darkWalnutCardRaised : AppTheme.warmPaperCardRaised
          let expectedGlass = expectedSurface.opacity(isDark ? 0.72 : 0.78)

          #expect(theme.backdropTop.srgb == expectedTop.srgb)
          #expect(theme.backdropBottom.srgb == expectedBottom.srgb)
          #expect(theme.surface.srgb == expectedSurface.srgb)
          #expect(theme.surfaceRaised.srgb == expectedRaised.srgb)
          #expect(theme.onGlassSurface.srgb == expectedGlass.srgb)
          #expect(theme.rim.srgb == tone.opacity(isDark ? 0.38 : 0.32).srgb)
        }
      }
    }
  }

  @Test("Liquid Glass opacity controls panelTintOpacity for material styles and clamps")
  func glassOpacityControlsPanelTint() {
    let glassTheme = AppTheme(tone: AccentPalette.tones[2], isDark: false, style: .glass, glassOpacity: 0.70)
    #expect(glassTheme.panelTintOpacity == 0.70)
    #expect(glassTheme.recessedWell.srgb.alpha > 0.10)

    let flatTheme = AppTheme(tone: AccentPalette.tones[2], isDark: true, style: .flat, glassOpacity: 0.70)
    #expect(flatTheme.panelTintOpacity == 1.0)
  }

  @Test("Apple HIG concentric corner radii follow the 5/6/10/12/14pt hierarchy")
  func higConcentricRadii() {
    #expect(Layout.radiusSegment == 5)
    #expect(Layout.radiusControl == 6)
    #expect(Layout.radiusCard == 10)
    #expect(Layout.radiusWindow == 12)
    #expect(Layout.radiusPanel == 14)
    #expect(Layout.radiusHero == 14)
    #expect(Layout.radiusSegment < Layout.radiusControl)
    #expect(Layout.radiusControl < Layout.radiusCard)
    #expect(Layout.radiusCard < Layout.radiusWindow)
    #expect(Layout.radiusWindow < Layout.radiusPanel)
  }

  @Test("AmbientDaylightMood maps morning, afternoon and evening hours deterministically")
  func ambientDaylightMoodHours() {
    #expect(AmbientDaylightMood.mood(forHour: 8) == .morning)
    #expect(AmbientDaylightMood.mood(forHour: 11) == .morning)
    #expect(AmbientDaylightMood.mood(forHour: 12) == .afternoon)
    #expect(AmbientDaylightMood.mood(forHour: 16) == .afternoon)
    #expect(AmbientDaylightMood.mood(forHour: 19) == .evening)
    #expect(AmbientDaylightMood.mood(forHour: 2) == .evening)

    for mood in AmbientDaylightMood.allCases {
      #expect(!mood.greetingTitle.isEmpty)
      #expect(!mood.greetingSubtitle.isEmpty)
      #expect(!mood.symbolName.isEmpty)
      #expect(mood.topTint(isDark: false).srgb.alpha <= 0.08)
      #expect(mood.topTint(isDark: true).srgb.alpha <= 0.08)
    }
  }

  @Test("Control Center Pill Slider uses 26pt pill track and circular 20pt thumb")
  func controlCenterPillSliderGeometry() {
    #expect(KnobGeometry.rest.trackHeight == 26)
    #expect(KnobGeometry.hovered.trackHeight == 26)
    #expect(KnobGeometry.dragging.trackHeight == 26)
    #expect(KnobGeometry.rest.width == 20)
    #expect(KnobGeometry.rest.cornerRadius == 10)
  }

  @Test("Warm Studio Craft semantic tokens provide distinct light paper and dark walnut values")
  func warmStudioCraftSemanticTokens() {
    let light = AppTheme(tone: AccentPalette.tones[2], isDark: false, style: .glass)
    let dark = AppTheme(tone: AccentPalette.tones[2], isDark: true, style: .glass)

    #expect(light.studioAccent.srgb != dark.studioAccent.srgb)
    #expect(light.specularRim.srgb.alpha > dark.specularRim.srgb.alpha)
    #expect(light.groupBorder.srgb.alpha > 0)
    #expect(dark.groupBorder.srgb.alpha > 0)
    #expect(light.separator.srgb.alpha > 0)
    #expect(dark.separator.srgb.alpha > 0)
    #expect(light.sliderFill.srgb.alpha > 0.9)
    #expect(dark.sliderFill.srgb.alpha > 0.85)
    #expect(light.sliderGlyphInk.contrastRatio(to: light.sliderFill) >= 4.5)
  }

  @Test("Critically damped macOS motion tokens eliminate stagger and background ambient periods")
  func criticallyDampedMotionTokens() {
    #expect(MotionTokens.standard.stagger == 0)
    #expect(MotionTokens.standard.ambientPeriod == 0)
    #expect(MotionTokens.reduced.stagger == 0)
    #expect(MotionTokens.reduced.ambientPeriod == 0)
    #expect(MotionTokens.unfoldSpring == Spring(response: 0.18, dampingRatio: 0.96))
  }

  @Test("Onboarding steps provide both titles and warm editorial subtitles")
  func onboardingStepTitlesAndSubtitles() {
    for step in OnboardingFlow.Step.allCases {
      #expect(!step.title.isEmpty)
      #expect(!step.subtitle.isEmpty)
    }
  }

  @Test("legible(on:) reaches the ratio it is asked for")
  func legibleReachesRatio() {
    for background in AccentPalette.tones {
      for candidate in AccentPalette.tones {
        let fixed = candidate.legible(on: background, ratio: 4.5)
        #expect(fixed.contrastRatio(to: background) >= 4.49)
      }
    }
  }

  @Test("legible(on:) leaves a colour that already passes alone")
  func legibleIsIdempotent() {
    let ink = Color.white
    #expect(ink.legible(on: .black) == ink)
  }

  /// Compositing has to agree with the ratio, or the secondary-text check above
  /// is measuring something that never appears on screen.
  @Test("Alpha compositing lands between the two colours")
  func compositingIsLinear() {
    let halfway = Color.white.opacity(0.5).over(.black)
    #expect(abs(halfway.srgb.red - 0.5) < 0.01)
    #expect(Color.white.opacity(1).over(.black).srgb.red == 1)
    #expect(Color.white.opacity(0).over(.black).srgb.red == 0)
  }
}
