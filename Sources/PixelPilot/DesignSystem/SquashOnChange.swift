import SwiftUI

/// One squash, played whenever `trigger` changes.
///
/// Three phases rather than two, and this is the whole reason the modifier is
/// fiddlier than it looks: a two-phase animator leaves the view resting at
/// whichever phase it ended on, and the resting size of a control is not
/// negotiable. Here the first and last phase are both "normal", so it returns
/// to itself whichever way the animator settles.
///
/// Under reduced motion the animator is not slowed down, it is removed — the
/// content passes through untouched and there is nothing left running.
struct SquashOnChange: ViewModifier {
  let trigger: Int
  /// How far it swells. Roughly 1.2 reads as a pop, roughly 1.1 as a tick.
  var peak: CGFloat = 1.22
  /// Getting there. Short and bouncy; this is the half that is felt.
  var rise: Animation = .spring(duration: 0.15, bounce: 0.5)
  /// Coming back. Usually the caller's `motion.expressive`.
  var settle: Animation
  var isReduced: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isReduced {
      content
    } else {
      content.phaseAnimator([0, 1, 2], trigger: trigger) { view, phase in
        view.scaleEffect(phase == 1 ? peak : 1)
      } animation: { phase in
        phase == 1 ? rise : settle
      }
    }
  }
}

extension View {
  /// The full pop, for a control letting go or bottoming out.
  func squashOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(trigger: trigger, settle: motion.expressive, isReduced: motion.isReduced))
  }

  /// The smaller tick, for passing a detent. Deliberately quieter than the
  /// release pop: crossing a mark happens several times in one drag, and at the
  /// same size as the release it would read as the control stuttering.
  func tickOnChange(_ trigger: Int, motion: MotionTokens) -> some View {
    modifier(SquashOnChange(
      trigger: trigger,
      peak: 1.08,
      rise: .spring(duration: 0.10, bounce: 0.45),
      settle: motion.effectDefault,
      isReduced: motion.isReduced
    ))
  }
}
