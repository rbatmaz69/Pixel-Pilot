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

  /// Strict Apple macOS Human Interface Guidelines (HIG) concentric radius scale.
  ///
  /// Outer containers wrap inner cards and controls concentrically:
  /// - `radiusWindow = 12pt`: Standard macOS `NSWindow` & `NSSheet` corner radius.
  /// - `radiusPanel = 14pt`: Menu Bar Popover & OSD Control Center Pill outer radius.
  /// - `radiusCard = 10pt`: Grouped `Form(.grouped)` containers & Control Center modules (`14pt - 4pt` padding).
  /// - `radiusControl = 6pt`: Native `NSButton` push buttons, sidebar selection rows, text fields & outer segmented wells.
  /// - `radiusSegment = 5pt`: Inner segment selection indicator & `20×20pt` category icon badges.
  /// - `radiusHero = 14pt`: OSD Pill & Identify Overlay plates.
  static let radiusSegment: CGFloat = 5
  /// Buttons, toggles, sidebar rows, outer segmented frame.
  static let radiusControl: CGFloat = 6
  /// `PanelCard` and grouped `Form(.grouped)` containers.
  static let radiusCard: CGFloat = 10
  /// Standard macOS `NSWindow` and `NSSheet` corner radius.
  static let radiusWindow: CGFloat = 12
  /// Menu Bar Popover and Control Center containers.
  static let radiusPanel: CGFloat = 14
  /// The OSD Pill and the identify overlay plate.
  static let radiusHero: CGFloat = 14
}

/// The type scale.
///
/// Combines clean SF Pro UI typography (`cardTitle`, `rowTitle`, `detail`),
/// tabular monospaced readouts (`readout`, `heroReadout`, `mono`), and warm
/// editorial New York serif accents (`editorialAccent`) for companion greetings,
/// atmospheric scene subtitles, and the Panel Care Seal.
enum TypeScale {
  static let cardTitle = Font.callout.weight(.semibold)
  static let rowTitle = Font.callout.weight(.medium)
  static let detail = Font.caption
  static let mono = Font.caption.monospaced()

  /// Warm editorial serif italic (New York) for companion headers, scene mood subtitles, and the Panel Care Seal.
  static let editorialAccent = Font.system(.caption, design: .serif).italic()

  /// Percentages and Kelvin readouts in the panel, HUD, and settings window.
  /// Monospaced digits keep `.numericText()` from shifting the row as the value changes.
  static let readout = Font.system(.callout, design: .default).weight(.semibold).monospacedDigit()
  static let heroReadout = Font.system(size: 26, weight: .semibold, design: .default).monospacedDigit()
  static let sheetTitle = Font.system(.title3, design: .default).weight(.semibold)

  /// The identify overlay's numeral. Sized to be read from across a desk rather
  /// than from in front of the keyboard, which is the whole point of it.
  static let identityNumeral = Font.system(size: 120, weight: .bold, design: .rounded)
}

/// What a card is sitting on.
///
/// Glass over glass goes milky: the effect samples what is behind it, and when
/// that is another glass surface the result is a flat wash with none of the
/// depth either layer was drawing for. The menu bar panel already gets its
/// material from its window, so its cards must not add a second one.
///
/// `.onOpaque` is the default deliberately. It is right for four of the five
/// scene roots, so a new window that forgets to declare anything gets the right
/// answer, and only the one exception has to remember — the opposite of
/// `.withMotionTokens()`, which has to be remembered everywhere and is the
/// reason `Layout` is a plain static in the first place.
enum SurfaceDepth {
  /// A window with its own opaque or vibrant background. Cards draw glass.
  case onOpaque
  /// Already inside a glass or material surface. Cards draw a tinted fill.
  case onGlass
}

extension EnvironmentValues {
  @Entry var surfaceDepth: SurfaceDepth = .onOpaque
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
