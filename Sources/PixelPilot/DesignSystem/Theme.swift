import SwiftUI

/// Spacing and corner radii as a scale rather than as scattered literals.
///
/// These are plain statics rather than environment values on purpose. Nothing
/// here varies with an accessibility setting or a colour scheme, and
/// `.withMotionTokens()` already has to be remembered at five scene roots —
/// a second modifier with the same failure mode is a second thing to forget.
enum Layout {
  static let hair: CGFloat = 2
  static let tight: CGFloat = 6
  static let snug: CGFloat = 10
  static let normal: CGFloat = 14
  static let loose: CGFloat = 20
  static let section: CGFloat = 26

  /// Softer than the system default. Generous radii are the cheapest way to
  /// read as playful — but only if they are consistent. Two radii that are
  /// close but not equal look like a mistake rather than a decision, which is
  /// the whole reason these live here instead of at the call site.
  static let radiusControl: CGFloat = 9
  static let radiusCard: CGFloat = 16
  static let radiusPanel: CGFloat = 22
  static let radiusHero: CGFloat = 28
}

/// The type scale.
///
/// SF Rounded for numbers and headings is the largest change in character
/// available without shipping a font: it is unmistakably softer than SF Pro
/// while still being a system face, so it stays legible at 9pt in a menu bar
/// panel. Body copy stays on SF Pro — rounded paragraphs read as a toy.
enum TypeScale {
  static let cardTitle = Font.callout.weight(.semibold)
  static let rowTitle = Font.callout.weight(.medium)
  static let detail = Font.caption
  static let mono = Font.caption.monospaced()

  /// Percentages in the panel and the window. Monospaced digits are what keep
  /// `.numericText()` from shuffling the whole row as the value changes.
  static let readout = Font.system(.callout, design: .rounded).weight(.semibold).monospacedDigit()
  static let heroReadout = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
  static let sheetTitle = Font.system(.title3, design: .rounded).weight(.semibold)
}

/// The three status colours, named by what they mean rather than by hue.
///
/// They were `Color.green` / `.orange` / `.red` at four call sites, which is
/// fine until one of them needs to change and only three get found.
enum Status {
  static let ok = Color.green
  static let warn = Color.orange
  static let bad = Color.red
  static let info = Color.blue
}
