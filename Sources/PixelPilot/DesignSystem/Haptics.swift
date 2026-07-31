import AppKit
import PixelPilotCore

/// The app's tactile vocabulary — three taps, named by what they mean.
///
/// Everything visible in this interface is designed to feel physical: the
/// handle morphs as it is grabbed, squashes when it bottoms out, and the
/// buttons sink under a press. All of that is a picture of a physical control.
/// On a Mac with a Force Touch trackpad it can be an actual one, for the cost
/// of three calls.
///
/// Three deliberate non-decisions, so they do not get made again by accident:
///
/// **No hardware check.** `NSHapticFeedbackManager.defaultPerformer` is
/// documented as choosing for the current input device, accessibility settings
/// and user preferences, and it does nothing on hardware that cannot vibrate.
/// A capability test here would be a worse copy of one the framework already
/// performs, and it would be the thing that gets an external Magic Trackpad
/// wrong.
///
/// **Not suppressed under Reduce Motion.** That setting is about *visible*
/// motion — and this app answers it by deleting animation from the hierarchy
/// rather than slowing it down, which removes precisely the visual
/// acknowledgement a haptic replaces. Taking the tap away too would leave the
/// people who asked for less movement with the least feedback of anyone. macOS
/// keeps a separate switch for haptics, and the default performer honours it.
///
/// **Only three moments.** Reaching an end, crossing a detent, and an action
/// landing. A tap on every value change would be noise, and noise is how a
/// feature like this gets switched off.
@MainActor
enum Haptics {
  private static var isEnabled: Bool { Preferences.shared.global.hapticsEnabled }

  /// Crossing one of a control's marks. The lightest of the three.
  static func detent() {
    perform(.alignment)
  }

  /// Bottoming out — the slider will not go further this way.
  static func endStop() {
    perform(.levelChange)
  }

  /// Something happened: a preset applied, a key captured.
  ///
  /// `.now` rather than `.default`, because these are not tied to anything
  /// being drawn. The others are, and deferring them to the frame that shows
  /// the change is what keeps the tap and the picture together.
  static func confirm() {
    perform(.generic, performanceTime: .now)
  }

  private static func perform(
    _ pattern: NSHapticFeedbackManager.FeedbackPattern,
    performanceTime: NSHapticFeedbackManager.PerformanceTime = .drawCompleted
  ) {
    guard isEnabled else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
  }
}
