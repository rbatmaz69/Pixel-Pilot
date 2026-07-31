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

  private struct Handled {
    let instant: ContinuousClock.Instant
    /// Whether the event was consumed, or passed on to macOS.
    let wasConsumed: Bool
  }

  private let window: Duration
  private var lastHandled: [Int: Handled] = [:]

  public init(window: Duration = defaultWindow) {
    self.window = window
  }

  /// Returns true when this event should be acted on.
  ///
  /// `key` identifies the action, not the source — that is the point: the same
  /// action from two different paths must collide.
  ///
  /// Callers that consume events want `previousDecision(for:at:)` instead, so
  /// the duplicate can be answered the same way the original was.
  public mutating func shouldHandle(
    key: Int, at instant: ContinuousClock.Instant = .now
  ) -> Bool {
    guard previousDecision(for: key, at: instant) == nil else { return false }
    record(true, for: key, at: instant)
    return true
  }

  /// What was decided about an identical press still inside the window, or nil
  /// when this is the first copy and the caller has to decide for itself.
  ///
  /// The distinction is the whole point, and getting it wrong is how the
  /// built-in display's brightness keys stop working: when the first copy is
  /// *declined* — because a built-in panel is deliberately left to macOS — the
  /// duplicate has to be declined too. Answering "already handled, consume it"
  /// swallows a key nobody acted on, and macOS never gets to dim the screen.
  public mutating func previousDecision(
    for key: Int, at instant: ContinuousClock.Instant = .now
  ) -> Bool? {
    guard let previous = lastHandled[key], instant - previous.instant < window else { return nil }
    return previous.wasConsumed
  }

  /// Remembers what was decided, so the second copy can answer identically.
  ///
  /// A duplicate deliberately does not call this: extending the window on every
  /// repeat would let a steady stream of them block the key indefinitely.
  public mutating func record(
    _ wasConsumed: Bool, for key: Int, at instant: ContinuousClock.Instant = .now
  ) {
    lastHandled[key] = Handled(instant: instant, wasConsumed: wasConsumed)
  }

  /// Forgets history, for when the set of input devices changes.
  public mutating func reset() {
    lastHandled.removeAll()
  }
}
