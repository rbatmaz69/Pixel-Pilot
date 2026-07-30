import SwiftUI

/// The motion vocabulary of the app, in one place.
///
/// The look is Apple — Liquid Glass, SF Pro, system metrics. The *movement* is
/// borrowed from Material 3 Expressive, which draws a distinction Apple's
/// defaults do not make explicit:
///
/// - **Spatial** springs move things through space and are allowed to overshoot.
///   Overshoot is what makes a control feel physical rather than animated.
/// - **Effect** springs change colour and opacity and must never overshoot.
///   A colour that overshoots reads as a flicker or a bug.
///
/// Using one curve for both is the single most common reason an interface feels
/// almost right and slightly cheap.
struct MotionTokens: Sendable, Equatable {
  // Spatial — position, size, shape.
  let spatialFast: Animation
  let spatialDefault: Animation
  let spatialSlow: Animation

  // Effects — colour, opacity, blur.
  let effectFast: Animation
  let effectDefault: Animation

  /// Noticeably more ring than `spatialDefault`. For entrances and press
  /// releases, where the overshoot *is* the point rather than a side effect of
  /// getting there quickly.
  let expressive: Animation

  /// Delay between neighbouring elements in a staggered entrance.
  ///
  /// Small on purpose. The panel is opened dozens of times a day, and an
  /// entrance that is enjoyable the first time is an obstacle the twentieth —
  /// the whole sequence has to be over before anyone would think to wait.
  let stagger: Double

  /// How long the ambient wash takes to drift from one pose to the other, in
  /// seconds. Zero means: do not move at all.
  let ambientPeriod: Double

  /// True when the tokens have been flattened for reduced motion.
  let isReduced: Bool

  static let standard = MotionTokens(
    spatialFast: .spring(duration: 0.28, bounce: 0.28),
    spatialDefault: .spring(duration: 0.42, bounce: 0.22),
    spatialSlow: .spring(duration: 0.60, bounce: 0.20),
    effectFast: .spring(duration: 0.18, bounce: 0.0),
    effectDefault: .spring(duration: 0.25, bounce: 0.0),
    expressive: .spring(duration: 0.52, bounce: 0.40),
    stagger: 0.045,
    ambientPeriod: 9,
    isReduced: false
  )

  /// Everything collapses to a short, bounce-free curve. Motion is not removed
  /// outright — an instant jump is its own kind of disorienting — it is made
  /// unremarkable.
  ///
  /// The two new tokens are the exception: a stagger of zero and a period of
  /// zero mean the staggered entrance lands all at once and the ambient drift
  /// stops entirely. Slowing a continuous animation down is the wrong answer
  /// here; someone who asked for less motion did not ask for lazier motion.
  static let reduced = MotionTokens(
    spatialFast: .smooth(duration: 0.12),
    spatialDefault: .smooth(duration: 0.15),
    spatialSlow: .smooth(duration: 0.20),
    effectFast: .smooth(duration: 0.12),
    effectDefault: .smooth(duration: 0.15),
    expressive: .smooth(duration: 0.15),
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
