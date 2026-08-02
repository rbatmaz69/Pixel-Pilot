import AppKit
import SwiftUI

/// Where the panel is between the status item and its full size.
///
/// Pure, and separated from the window for the same reason `BrightnessMapping`
/// is separated from the controller that uses it: this is the arithmetic that
/// is easy to get subtly wrong and hard to see going wrong. A frame that is a
/// few points off for two frames of an animation is invisible in review and
/// obvious on screen, and the invariant below — that the content's scale is
/// always the frame's own proportion — is the one holding the window and the
/// layer transform together. They are driven from one number precisely so they
/// cannot disagree, and this is that number's only interpreter.
enum PanelPresentation {
  /// How tall the collapsed panel is, as a fraction of its resting height.
  ///
  /// Not zero. A window with no pixels has nothing to blur behind it and blinks
  /// out a frame early, and the last thing anyone sees on the way out should be
  /// the panel rolling up rather than vanishing.
  static let collapsedScale: CGFloat = 0.06

  /// The frame for a given progress, where 0 is rolled up under the menu bar
  /// and 1 is the panel at rest.
  ///
  /// **Only the height moves.** The first version scaled both axes, so that the
  /// panel appeared to grow out of the status item — and the contents sprang
  /// horizontally with it, which reads as the interface being stretched rather
  /// than opened. Nothing in a panel wants to be narrower than it is: the
  /// sliders, the readouts and the text all have one correct width, and any
  /// other width is a distortion of it. Height is different — a panel that is
  /// not yet fully unrolled is not a distorted panel, it is a partly revealed
  /// one, which is what every menu on this system does.
  ///
  /// So the width and the horizontal position are fixed at their resting
  /// values, the top edge is pinned just under the status item, and the panel
  /// unrolls downward. The contents are never scaled at all — see
  /// `MenuBarPanelWindow.apply(progress:)`, where they are simply re-hung from
  /// the top and clipped by the window.
  ///
  /// Values above 1 are expected: the spring arrives slightly too tall and
  /// settles back. They are not clamped for that reason. What *is* guarded is
  /// the bottom — a spring can undershoot below zero on the way out, and a
  /// negative height is not a shorter window but an inverted one.
  static func frame(progress: CGFloat, target: CGRect) -> CGRect {
    let scale = max(collapsedScale, collapsedScale + (1 - collapsedScale) * progress)
    let height = target.height * scale

    return CGRect(
      x: target.minX,
      // Grows downward from the top edge, which is where the status item is.
      y: target.maxY - height,
      width: target.width,
      height: height
    )
  }

  /// How much the contents stretch to keep up with an overshooting window.
  ///
  /// **Never below 1**, and that asymmetry is the design. While the panel is
  /// unrolling the contents must not be squashed — they are being revealed, not
  /// resized, which is the whole reason nothing in here is scaled during the
  /// opening. But once the spring carries the window past its resting height
  /// there is more window than there is content, and the difference shows as a
  /// band of empty tint under the last row.
  ///
  /// Stretching to meet it turns that gap into the panel arriving with some
  /// give in it. Vertical only, so no readout and no slider is ever drawn at a
  /// width other than its own; a few per cent for a hundred milliseconds along
  /// the axis that is already moving reads as elasticity rather than as
  /// distortion. It is also the pop: without it the bounce has nowhere to go
  /// but into a hole at the bottom of the panel.
  static func contentStretch(frame: CGRect, target: CGRect) -> CGFloat {
    guard target.height > 0 else { return 1 }
    return max(1, frame.height / target.height)
  }

  /// Opacity over the run. Fully in by the time the panel is a bit over half
  /// open — the fade is there to cover the first frame of compositing, not to
  /// be a second animation competing with the movement.
  static func alpha(progress: CGFloat) -> CGFloat {
    min(1, max(0, progress / 0.55))
  }
}

/// Runs a spring for as long as it takes and then stops existing.
///
/// A display link rather than `NSAnimationContext`, because the window frame and
/// a layer transform have to be set from the *same* value on the *same* frame.
/// Two animations sharing a timing function would still be two animations, and
/// the visible result of them drifting is the panel's material sliding out from
/// under its own contents — the artefact this whole area was just fixed for.
///
/// It also keeps the app's one hard rule. The link is created when a movement
/// starts and invalidated the moment it settles, so there is nothing scheduled
/// between them.
@MainActor
final class PanelSpringDriver {
  private var link: CADisplayLink?
  private var start: CFTimeInterval = 0
  private var spring: Spring = MotionTokens.expressiveSpring
  private var onFrame: ((CGFloat) -> Void)?
  private var onFinish: (() -> Void)?
  private var isReversed = false

  var isRunning: Bool { link != nil }

  /// - Parameters:
  ///   - view: any view in the window being animated; the link is bound to its
  ///     screen, so a panel on a 120 Hz display gets 120 Hz.
  ///   - reversed: run the spring from 1 down to 0 rather than 0 up to 1.
  ///   - onFrame: called with the current progress, every frame.
  ///   - onFinish: called once, after the final frame has been delivered.
  func run(
    in view: NSView,
    spring: Spring,
    reversed: Bool,
    onFrame: @escaping (CGFloat) -> Void,
    onFinish: @escaping () -> Void
  ) {
    cancel()

    self.spring = spring
    self.isReversed = reversed
    self.onFrame = onFrame
    self.onFinish = onFinish
    start = CACurrentMediaTime()

    // Delivered on the first frame rather than only from the next tick, so the
    // window is never shown at its resting size for one frame before starting
    // to grow.
    onFrame(reversed ? 1 : 0)

    let link = view.displayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  /// Stops without calling `onFinish`. For the case where something else has
  /// taken over — a second click while the panel is still collapsing.
  func cancel() {
    link?.invalidate()
    link = nil
    onFrame = nil
    onFinish = nil
  }

  @objc private func tick() {
    let elapsed = CACurrentMediaTime() - start
    let settled = elapsed >= spring.settlingDuration

    let value = spring.value(target: 1, time: elapsed)
    let progress: CGFloat = isReversed ? 1 - CGFloat(value) : CGFloat(value)
    onFrame?(settled ? (isReversed ? 0 : 1) : progress)

    guard settled else { return }
    // Read out before tearing down: `cancel()` clears them, and a completion
    // that re-enters this driver — which closing does — must not have its own
    // callbacks pulled out from under it.
    let finish = onFinish
    cancel()
    finish?()
  }

  // No `deinit` invalidating the link, and that is not an oversight: a display
  // link cannot be touched from a nonisolated deinit, and there is nothing for
  // one to clean up anyway. Every path that starts a run ends in `cancel()` —
  // the tick that settles, a caller taking over, or the panel tearing down —
  // and this object is owned for the lifetime of the window that drives it.
}
