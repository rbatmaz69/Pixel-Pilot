import SwiftUI

/// Tactile Aperture state-change pulse modifier.
///
/// Uses a single-shot 3-phase `phaseAnimator` (`0 -> 1 -> 2`) on `trigger`
/// changes to deliver a subtle mechanical detent impulse (`1.045x`) before
/// settling crisply back to rest (`1.0`), respecting `Reduce Motion`.
struct SquashOnChange: ViewModifier {
  let trigger: Int
  var peak: CGFloat = 1.045
  var rise: Animation = .spring(duration: 0.12, bounce: 0.2)
  var settle: Animation
  var isReduced: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isReduced {
      content
    } else {
      content.phaseAnimator([0, 1, 2], trigger: trigger) { view, phase in
        view.scaleEffect(phase == 1 ? peak : 1.0)
      } animation: { phase in
        switch phase {
        case 1: rise
        case 2: settle
        default: .linear(duration: 0.01)
        }
      }
    }
  }
}

/// Edge anchor direction for `directionalBoundarySquash`.
enum BoundarySquashDirection: Sendable, Equatable {
  case leading
  case trailing

  var anchor: UnitPoint {
    switch self {
    case .leading: .leading
    case .trailing: .trailing
    }
  }
}

private struct DirectionalBoundarySquash<T: Equatable>: ViewModifier {
  let trigger: T
  let direction: BoundarySquashDirection
  let motion: MotionTokens

  @ViewBuilder
  func body(content: Content) -> some View {
    if motion.isReduced {
      content
    } else {
      content.phaseAnimator([0, 1, 2], trigger: trigger) { view, phase in
        view.scaleEffect(
          x: phase == 1 ? 1.018 : 1.0,
          y: phase == 1 ? 0.985 : 1.0,
          anchor: direction.anchor
        )
      } animation: { phase in
        switch phase {
        case 1: .spring(duration: 0.08, bounce: 0.0)
        case 2: motion.tactileSnap ?? motion.expressive
        default: .linear(duration: 0.01)
        }
      }
    }
  }
}

extension View {
  /// Subtle mechanical detent squash played once whenever `trigger` changes.
  func squashOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(
      trigger: trigger,
      peak: 1.045,
      rise: .spring(duration: 0.12, bounce: 0.2),
      settle: motion.expressive,
      isReduced: motion.isReduced
    ))
  }

  /// Crisp micro-tick pulse on numeric readouts when crossing a detent.
  func tickOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(
      trigger: trigger,
      peak: 1.045,
      rise: .spring(duration: 0.10, bounce: 0.2),
      settle: motion.effectDefault,
      isReduced: motion.isReduced
    ))
  }

  /// Direction-aware elastic boundary compression when hitting `0%` or `100%`.
  func directionalBoundarySquash<T: Equatable>(
    trigger: T,
    direction: BoundarySquashDirection,
    motion: MotionTokens
  ) -> some View {
    modifier(DirectionalBoundarySquash(trigger: trigger, direction: direction, motion: motion))
  }
}
