import SwiftUI

/// A full-screen image for finding what is wrong with a panel.
///
/// Each one exists because it answers a question a slider cannot. The order is
/// the order to walk them in: the solids first, because a dead pixel makes
/// everything below it moot, then the ones that need a careful look.
///
/// Kept as a value with its own name and reason rather than as a list of
/// colours, so the overlay can say what it is asking you to look for. A test
/// pattern nobody can interpret is a coloured screen.
enum TestPattern: String, CaseIterable, Identifiable, Hashable {
  case white
  case black
  case red
  case green
  case blue
  case greyRamp
  case shadowSteps
  case highlightSteps
  case uniformityMid
  case uniformityDark
  case checkerboard

  var id: String { rawValue }

  var title: String {
    switch self {
    case .white: "White"
    case .black: "Black"
    case .red: "Red"
    case .green: "Green"
    case .blue: "Blue"
    case .greyRamp: "Grey ramp"
    case .shadowSteps: "Shadows"
    case .highlightSteps: "Highlights"
    case .uniformityMid: "Uniformity, mid grey"
    case .uniformityDark: "Uniformity, dark"
    case .checkerboard: "One-pixel checkerboard"
    }
  }

  /// What to look for. Shown next to the title, because "here is a red screen"
  /// is not an instruction.
  var purpose: String {
    switch self {
    case .white:
      "Dark specks are dead pixels; coloured ones are stuck sub-pixels. Also shows dust."
    case .black:
      "Bright specks are stuck pixels. Glow at the edges is backlight bleed."
    case .red, .green, .blue:
      "A pixel that stays dark on one colour and not the others has a dead sub-pixel."
    case .greyRamp:
      "Should be a smooth sweep. Visible steps or bands are the panel quantising."
    case .shadowSteps:
      "Five near-black steps. If the darkest ones merge, shadow detail is being crushed."
    case .highlightSteps:
      "Five near-white steps. If they merge, highlights are clipping."
    case .uniformityMid:
      "Should be flat. Patches and tints are clouding or an uneven backlight."
    case .uniformityDark:
      "The same, where backlight unevenness shows most."
    case .checkerboard:
      "At native resolution this reads as flat grey. If you can see the pattern, "
        + "the picture is being scaled."
    }
  }
}
