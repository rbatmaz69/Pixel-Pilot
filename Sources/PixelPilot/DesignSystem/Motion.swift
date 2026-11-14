import SwiftUI

/// The motion vocabulary of the app, in one place.
///
/// Implements the "Tactile Aperture & Kinetic Light Physics" language:
/// optically crisp mechanical detents, subtle cushion springs (`unfoldSpring`
/// & `tactileSnap`), `0ms` direct drag tracking, and zero continuous
/// background loops (`ambientPeriod = 0` for `0.0%` idle CPU).
struct MotionTokens: Sendable, Equatable {
  // Spatial — position, size, shape.
  let spatialFast: Animation
  let spatialDefault: Animation
  let spatialSlow: Animation

  // Effects — colour, opacity, blur.
  let effectFast: Animation
  let effectDefault: Animation

  /// Tactile curve for entrances, ghost previews, and state transitions.
  let expressive: Animation

  /// Crisp aperture snap for pill pickers, toggles, and detent plucks (`nil` when reduced).
  let tactileSnap: Animation?

  /// 120 Hz spring curve shared with AppKit drawers and height morphs.
  let drawerSpring: Spring

  /// Delay between neighbouring elements in an entrance cascade (`0` when reduced).
  let stagger: Double

  /// How long the ambient wash takes to drift (`0` = static, 0.0% idle CPU).
  let ambientPeriod: Double

  /// True when the tokens have been flattened for reduced motion.
  let isReduced: Bool

  /// Convenience alias matching shared static spring naming.
  var expressiveSpring: Animation { expressive }

  /// Tactile spring (`0.20s`, `bounce: 0.12`) shared between SwiftUI and AppKit.
  static let expressiveSpring = Spring(duration: 0.20, bounce: 0.12)

  /// Critically damped shutter-unroll curve for the menu bar popover (`response: 0.20`, `dampingRatio: 1.0`).
  static let unfoldSpring = Spring(response: 0.20, dampingRatio: 1.0)

  /// Crisp menu bar popover collapse (`0.14s`, `bounce: 0.0`).
  static let collapseSpring = Spring(duration: 0.14, bounce: 0.0)

  /// 120 Hz drawer expansion/collapse curve (`response: 0.22`, `dampingRatio: 0.88`).
  static let drawerSpring = Spring(response: 0.22, dampingRatio: 0.88)

  static let standard = MotionTokens(
    spatialFast: .spring(duration: 0.14, bounce: 0.0),
    spatialDefault: .spring(duration: 0.20, bounce: 0.10),
    spatialSlow: .spring(duration: 0.24, bounce: 0.08),
    effectFast: .spring(duration: 0.12, bounce: 0.0),
    effectDefault: .spring(duration: 0.18, bounce: 0.0),
    expressive: .spring(expressiveSpring),
    tactileSnap: .spring(duration: 0.20, bounce: 0.18),
    drawerSpring: MotionTokens.drawerSpring,
    stagger: 0.022,
    ambientPeriod: 0,
    isReduced: false
  )

  /// Reduced motion curve.
  static let reduced = MotionTokens(
    spatialFast: .smooth(duration: 0.10),
    spatialDefault: .smooth(duration: 0.12),
    spatialSlow: .smooth(duration: 0.15),
    effectFast: .smooth(duration: 0.10),
    effectDefault: .smooth(duration: 0.12),
    expressive: .smooth(duration: 0.12),
    tactileSnap: nil,
    drawerSpring: Spring(duration: 0.12, bounce: 0.0),
    stagger: 0,
    ambientPeriod: 0,
    isReduced: true
  )

  static func resolved(reduceMotion: Bool) -> MotionTokens {
    reduceMotion ? .reduced : .standard
  }
}

extension EnvironmentValues {
  /// Injected once at the root of each scene by `.withMotionTokens()`, so no
  /// view has to remember to check the accessibility setting itself.
  @Entry var motion: MotionTokens = .standard
}

extension View {
  /// Resolves the motion tokens against the current accessibility settings and
  /// puts them in the environment.
  func withMotionTokens() -> some View {
    modifier(MotionTokenResolver())
  }
}

private struct MotionTokenResolver: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.environment(\.motion, .resolved(reduceMotion: reduceMotion))
  }
}
