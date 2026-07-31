import AppKit

/// The menu bar icon.
///
/// The poppy from the app icon, as a template image — macOS keeps only its
/// alpha and tints the result for light, dark and tinted menu bars, which is
/// why one asset covers all three.
///
/// Deliberately the same mark as the app icon, and deliberately unchanging. A
/// menu bar app has exactly one place it can be recognised; a second glyph
/// there, or one that moved with the brightness, would mean the app looked like
/// a different program depending on when you glanced at it. The level has a
/// place to be shown already, and it is the on-screen indicator.
@MainActor
enum StatusIconRenderer {
  static var image: NSImage {
    guard let image = NSImage(named: "MenuBarIcon") else {
      // Only reachable if the asset catalogue is broken, and a menu bar item
      // with no image is one with nothing to click.
      return NSImage(
        systemSymbolName: "sun.max", accessibilityDescription: "Pixel Pilot"
      ) ?? NSImage()
    }
    image.isTemplate = true
    return image
  }
}
