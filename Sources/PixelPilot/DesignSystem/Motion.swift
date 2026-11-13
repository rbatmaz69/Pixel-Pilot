import SwiftUI

/// The motion vocabulary of the app, in one place.
///
/// Follows Apple's macOS Human Interface Guidelines (HIG): critically damped
/// springs (`bounce: 0.0` / `dampingFraction: 0.96–1.0`) with zero overshoot
/// and zero rubber-band wobble, instantaneous button press states (`0ms`), and
/// zero continuous background animations (`ambientPeriod = 0` for `0.0%` idle CPU).
struct MotionTokens: Sendable, Equatable {
  // Spatial — position, size, shape (critically damped, zero bounce).
  let spatialFast: Animation
  let spatialDefault: Animation
  let spatialSlow: Animation

  // Effects — colour, opacity, blur.
  let effectFast: Animation
  let effectDefault: Animation

  /// Critically damped settle curve for entrances and state transitions.
  let expressive: Animation

  /// Delay between neighbouring elements in an entrance (`0` for instantaneous macOS layout).
  let stagger: Double

  /// How long the ambient wash takes to drift (`0` = static, 0.0% idle CPU).
  let ambientPeriod: Double

  /// True when the tokens have been flattened for reduced motion.
  let isReduced: Bool

  /// Critically damped spring (`0.18s`, `bounce: 0.0`) shared between SwiftUI and AppKit.
  static let expressiveSpring = Spring(duration: 0.18, bounce: 0.0)

  /// Critically damped menu bar popover unfold (`response: 0.18`, `dampingRatio: 0.96`).
  /// Settles cleanly without vertical rubber-band overshoot.
  static let unfoldSpring = Spring(response: 0.18, dampingRatio: 0.96)

  /// Crisp menu bar popover collapse (`0.12s`, `bounce: 0.0`).
  static let collapseSpring = Spring(duration: 0.12, bounce: 0)

  static let standard = MotionTokens(
    spatialFast: .spring(duration: 0.14, bounce: 0.0),
    spatialDefault: .spring(duration: 0.18, bounce: 0.0),
    spatialSlow: .spring(duration: 0.22, bounce: 0.0),
    effectFast: .spring(duration: 0.12, bounce: 0.0),
    effectDefault: .spring(duration: 0.18, bounce: 0.0),
    expressive: .spring(expressiveSpring),
    stagger: 0,
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
