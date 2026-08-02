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

  /// The expressive spring as a `Spring` rather than an `Animation`.
  ///
  /// An `Animation` is opaque: the duration and bounce that went into it cannot
  /// be read back out. That is fine while everything animating is SwiftUI, and
  /// stops being fine the moment AppKit has to move in step with it — the menu
  /// bar panel's window frame cannot be handed a SwiftUI `Animation`, so it
  /// would otherwise need a second set of spring constants meaning the same
  /// thing. Two such sets drift; someone retunes one and the window and the
  /// cards inside it stop agreeing.
  ///
  /// `Spring` is the same maths in a form both sides can use: SwiftUI takes it
  /// through `.spring(_:)` below, and AppKit evaluates it per frame with
  /// `value(target:time:)`. One set of numbers, agreeing by construction.
  static let expressiveSpring = Spring(duration: 0.52, bounce: 0.40)

  /// The menu bar panel unrolling. Springier than the effect curves and
  /// noticeably gentler than `expressiveSpring`, which is not timidity.
  ///
  /// A bounce that flatters a 40 pt card is a wobble on a 400 pt panel — the
  /// overshoot is a fraction of the thing that carries it, so the same number
  /// buys ten times the travel.
  ///
  /// The overshoot is where the pop lives, and it is only affordable because
  /// `PanelPresentation.contentStretch` gives it somewhere to go: the contents
  /// stretch to meet an over-tall window instead of leaving a band of empty
  /// tint under the last row. Without that this number has to stay timid.
  static let unfoldSpring = Spring(duration: 0.40, bounce: 0.34)

  /// The collapse. Deliberately not the spring above played backwards: an
  /// entrance may overshoot because arriving is the event, but leaving is not
  /// an event and a panel that bounced on its way out would be asking for
  /// attention it no longer deserves. Shorter, and with no bounce at all.
  static let collapseSpring = Spring(duration: 0.28, bounce: 0)

  static let standard = MotionTokens(
    spatialFast: .spring(duration: 0.28, bounce: 0.28),
    spatialDefault: .spring(duration: 0.42, bounce: 0.22),
    spatialSlow: .spring(duration: 0.60, bounce: 0.20),
    effectFast: .spring(duration: 0.18, bounce: 0.0),
    effectDefault: .spring(duration: 0.25, bounce: 0.0),
    expressive: .spring(expressiveSpring),
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
