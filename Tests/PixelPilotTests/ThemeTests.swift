import CoreGraphics
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
  private static let themes: [AppTheme] = AccentPalette.tones.flatMap { tone in
    AccentPalette.tones.flatMap { field in
      [
        AppTheme(tone: tone, backdropTone: field, isDark: true),
        AppTheme(tone: tone, backdropTone: field, isDark: false),
      ]
    }
  }

  private static func describe(_ theme: AppTheme) -> String {
    "\(theme.isDark ? "dark" : "light") \(theme.tone) on \(theme.backdropTone)"
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

  /// Not a grey, and not the raw tone either. The first is the whole point of
  /// the feature; the second would make body copy a saturated colour.
  @Test("Every surface keeps the colour it was derived from")
  func surfacesStayColoured() {
    for theme in Self.themes {
      let components = theme.backdropTop.srgb
      let spread = max(components.red, components.green, components.blue)
        - min(components.red, components.green, components.blue)
      #expect(spread > 0.01, "\(Self.describe(theme)) is grey — \(components)")
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
  @MainActor
  @Test("A card renders as the surface the theme describes")
  func cardRendersAsItsSurface() throws {
    let theme = AppTheme(tone: AccentPalette.tones[0], isDark: true)

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

    // What the card is specified to be: the theme's surface with the accent
    // wash over it — see `CardSurface`.
    let expected = theme.tone.accentWash.over(theme.surface)
    for sample in samples {
      #expect(
        sample.contrastRatio(to: expected) < 1.05,
        "rendered \(sample.srgb) against expected \(expected.srgb)"
      )
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
