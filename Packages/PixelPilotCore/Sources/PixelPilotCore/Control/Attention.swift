import CoreGraphics
import Foundation

/// How far the screens you are not working on are pushed back.
///
/// Off until asked for, like the schedule and like following. An app that
/// started changing the brightness on its own without being asked would be a
/// fault rather than a feature, and this one changes it on every window switch.
public struct AttentionSettings: Codable, Sendable, Equatable {
  public var isEnabled: Bool = false

  /// How far an unfocused display sinks, as a fraction taken off its light.
  ///
  /// The band is narrow on purpose. Below a tenth nobody would notice it and
  /// the feature is a placebo; above roughly two thirds it has stopped meaning
  /// "pushed back" and started meaning "switched off", and there is already a
  /// control for that which does not undo itself when you look away.
  public static let amountRange: ClosedRange<Double> = 0.1 ... 0.7

  public var amount: Double = 0.35

  public init() {}

  /// The veil a display gets at this setting: 1 is untouched.
  public var veil: Double {
    1 - min(Self.amountRange.upperBound, max(Self.amountRange.lowerBound, amount))
  }

  /// Written by hand for the reason on `GlobalSettings.init(from:)`: this lives
  /// inside a blob whose decode failure is swallowed, so a field added later
  /// must come back absent rather than throw and take the theme, the schedule
  /// and the key settings with it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = AttentionSettings()
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
    amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? fallback.amount
  }
}

/// Which displays sink and which stays, given what is known right now.
///
/// A plain function over plain values, deliberately: the interesting part of
/// this feature is the decision, and the decision is the part that must be
/// right when nobody can be found, when there is only one screen, and when a
/// display has opted out. None of those need Accessibility, a window server or
/// a monitor to test — but they would all need one if the rule lived inside the
/// controller that observes focus.
public enum AttentionPlan {
  /// A display, as far as this decision is concerned.
  public struct Candidate: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    /// Whether this panel is willing to sink at all.
    public let participates: Bool

    public init(displayID: CGDirectDisplayID, participates: Bool) {
      self.displayID = displayID
      self.participates = participates
    }
  }

  /// The veil each display should be carrying, keyed by display.
  ///
  /// Every candidate appears in the result, including the ones that stay at 1 —
  /// a display left out of the answer is a display whose veil never gets
  /// lifted, which is the shape of bug that ends with somebody staring at a
  /// screen that will not come back.
  ///
  /// - Parameter focused: The screen holding the focused window, if that can be
  ///   established. Nil is a *normal* answer, not a failure.
  /// - Parameter pointer: Where the pointer is, used only when `focused` cannot
  ///   be resolved.
  ///
  ///   This fallback is the difference between the feature working and the
  ///   feature looking broken. Clicking a screen's desktop makes the Finder
  ///   frontmost with no focused window, so `focused` is nil — and without a
  ///   second answer every veil lifts and clicking a screen appears to do
  ///   nothing at all. `KeyTargetPolicy` makes the same fallback for the same
  ///   reason.
  ///
  ///   Reading the pointer *at the moment a focus event arrives* is a single
  ///   query and is not the continuously-monitored pointer-following that was
  ///   turned down: nothing here watches the mouse move.
  public static func veils(
    for candidates: [Candidate],
    focused: CGDirectDisplayID?,
    pointer: CGDirectDisplayID? = nil,
    settings: AttentionSettings
  ) -> [CGDirectDisplayID: Double] {
    let clear = Dictionary(uniqueKeysWithValues: candidates.map { ($0.displayID, 1.0) })

    guard settings.isEnabled else { return clear }

    // One screen has nothing to be compared against, and the only display there
    // is must never be the one that sinks.
    guard candidates.count > 1 else { return clear }

    let known = { (id: CGDirectDisplayID?) -> CGDirectDisplayID? in
      id.flatMap { value in candidates.contains { $0.displayID == value } ? value : nil }
    }

    // With neither answer there is no screen this can be sure the person is
    // looking at, and veiling all of them because nobody could be found is the
    // failure where the user cannot see what to click to undo it.
    guard let attended = known(focused) ?? known(pointer) else { return clear }

    let veil = settings.veil
    return Dictionary(uniqueKeysWithValues: candidates.map { candidate in
      let sinks = candidate.participates && candidate.displayID != attended
      return (candidate.displayID, sinks ? veil : 1.0)
    })
  }
}
