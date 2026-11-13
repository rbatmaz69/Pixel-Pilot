import SwiftUI

/// Native macOS HIG state-change modifier.
///
/// Rubber-band scale distortion (`1.22x` / `1.08x`) is neutralized (`peak = 1.0`)
/// so controls, numeric readouts, and glyphs remain geometrically stable like
/// native AppKit / Control Center controls while keeping `.numericText()` transitions.
struct SquashOnChange: ViewModifier {
  let trigger: Int
  var peak: CGFloat = 1.0
  var rise: Animation = .spring(duration: 0.12, bounce: 0.0)
  var settle: Animation
  var isReduced: Bool

  func body(content: Content) -> some View {
    content
  }
}

extension View {
  /// Kept for call-site compatibility; passes content through without rubber-band scaling.
  func squashOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(trigger: trigger, settle: motion.expressive, isReduced: motion.isReduced))
  }

  /// Kept for call-site compatibility; passes content through without rubber-band scaling.
  func tickOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(
      trigger: trigger,
      peak: 1.0,
      rise: .spring(duration: 0.10, bounce: 0.0),
      settle: motion.effectDefault,
      isReduced: motion.isReduced
    ))
  }
}
