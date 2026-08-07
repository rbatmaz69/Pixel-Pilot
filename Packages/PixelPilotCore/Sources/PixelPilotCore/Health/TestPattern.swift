import Foundation

/// A full-screen image for finding what is wrong with a panel.
///
/// Each one exists because it answers a question a slider cannot. The order is
/// the order to walk them in: the solids first, because a dead pixel makes
/// everything below it moot, then the ones that need a careful look.
///
/// Kept as a value with its own name and reason rather than as a list of
/// colours, so the overlay can say what it is asking you to look for. A test
/// pattern nobody can interpret is a coloured screen.
///
/// **This lives in the package rather than beside the view that draws it**
/// because `HealthReport` has to name the patterns it holds verdicts for, and
/// it is persisted. Nothing here touches SwiftUI; the drawing stays in
/// `TestPatternView`.
///
/// **The raw values are storage.** Renaming a case does not fail to compile and
/// does not fail to decode — it silently turns every stored verdict for that
/// pattern into "never answered" on every machine the app is installed on.
/// `HealthReportTests` pins them against a literal list for exactly that reason.
public enum TestPattern: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
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

  public var id: String { rawValue }

  public var title: String {
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
  public var purpose: String {
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

  /// What it means when somebody says this pattern looked wrong.
  ///
  /// Three genuinely different answers, and folding them together is what makes
  /// a health report useless. A bright speck on black is a broken panel.
  /// Visible banding on the grey ramp is what this panel is like — nothing is
  /// broken and nothing can be fixed. A visible one-pixel checkerboard is a
  /// *resolution setting*, and the display is fine. A single "3 problems found"
  /// would report all three the same way.
  public var problemClass: ProblemClass {
    switch self {
    case .white, .black, .red, .green, .blue: .pixelFault
    case .greyRamp, .shadowSteps, .highlightSteps, .uniformityMid, .uniformityDark: .panelQuality
    case .checkerboard: .configuration
    }
  }

  /// Which way anything drawn over this pattern has to go to stay visible.
  ///
  /// Returned as a choice rather than a colour so the package stays free of
  /// SwiftUI. The overlay resolves it to black or white — and to nothing else,
  /// for the reason `TestPatternController` already gives about the accent:
  /// furniture tinted by the app's theme would be part of the measurement.
  public var ink: Ink {
    switch self {
    case .white, .greyRamp, .highlightSteps, .uniformityMid: .dark
    default: .light
    }
  }
}

/// The kind of answer a flagged pattern is.
public enum ProblemClass: String, Codable, Sendable, CaseIterable {
  /// Something is wrong with the panel's pixels. The only class the repair
  /// function has any theory about.
  case pixelFault
  /// The panel is behaving as itself. Worth knowing, not worth fixing.
  case panelQuality
  /// Nothing is wrong with the display at all — it is being driven wrongly.
  case configuration

  public var displayName: String {
    switch self {
    case .pixelFault: "Pixel faults"
    case .panelQuality: "Panel behaviour"
    case .configuration: "How it's being driven"
    }
  }
}

/// Which way a mark has to be drawn to be seen against what is under it.
public enum Ink: String, Sendable, Hashable {
  case dark
  case light
}
