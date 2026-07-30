import Foundation

/// Drops the second copy of a media key press.
///
/// The same physical key can arrive twice. macOS translates media keys it
/// recognises into system-defined events, which the event tap sees; the app also
/// listens at the HID layer to catch keyboards macOS does *not* translate. On a
/// keyboard where both paths work, one press produces two events.
///
/// Without this the brightness jumps two steps per press — an error that reads
/// as "the app is broken", not as "an event arrived twice".
///
/// Deliberately not solved by preferring one source. Which source works depends
/// on the keyboard, and a keyboard can be unplugged mid-session; whichever event
/// arrives first wins, and the other is discarded.
public struct MediaKeyDeduplicator: Sendable {
  /// How long after handling a key the same key is treated as a duplicate.
  ///
  /// Long enough to cover the gap between the two paths, short enough not to eat
  /// a genuine second press. Key repeat runs at roughly 30 ms once it gets
  /// going, so this has to stay well below that.
  public static let defaultWindow: Duration = .milliseconds(20)

  private let window: Duration
  private var lastSeen: [Int: ContinuousClock.Instant] = [:]

  public init(window: Duration = defaultWindow) {
    self.window = window
  }

  /// Returns true when this event should be acted on.
  ///
  /// `key` identifies the action, not the source — that is the point: the same
  /// action from two different paths must collide.
  public mutating func shouldHandle(
    key: Int, at instant: ContinuousClock.Instant = .now
  ) -> Bool {
    if let previous = lastSeen[key], instant - previous < window {
      return false
    }
    lastSeen[key] = instant
    return true
  }

  /// Forgets history, for when the set of input devices changes.
  public mutating func reset() {
    lastSeen.removeAll()
  }
}
