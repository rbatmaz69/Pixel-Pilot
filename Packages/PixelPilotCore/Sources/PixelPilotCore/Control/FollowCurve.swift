import Foundation

/// How one display's brightness is derived from another's.
///
/// The obvious implementation is an offset — the external display sits N per
/// cent below the built-in one — and it is wrong in a way that only shows up in
/// a dark room. The two panels have nothing in common: their backlight ranges
/// differ, their idea of "half" differs, and the built-in one is being driven by
/// an ambient light sensor whose bottom end means "almost no light in the room",
/// not "turn the monitor off". An offset drags the external panel to black
/// there. So does a multiplier.
///
/// Two anchors and a straight line between them says the thing that is actually
/// true: *at this ambient level I want that brightness, and at that one I want
/// this*. Outside the anchors it holds rather than extrapolating — an anchor
/// pair that happens to sit in the middle of the range must not fling the
/// display to either extreme at the ends.
///
/// The curve is not configured. It is **taught**, by adjusting the display by
/// hand while it is following, which is the only moment anyone actually knows
/// what they want. See `learn(source:target:)`.
public struct FollowCurve: Codable, Sendable, Equatable {
  /// One taught pair: where the source display was, and where this display
  /// should be when it is there again.
  public struct Anchor: Codable, Sendable, Equatable {
    /// The source display's brightness, 0...1.
    public var source: Double
    /// What this display should be at, 0...1.
    public var target: Double

    public init(source: Double, target: Double) {
      self.source = min(1, max(0, source))
      self.target = min(1, max(0, target))
    }
  }

  public var lower: Anchor
  public var upper: Anchor

  /// How close the two anchors may get, measured on the source axis.
  ///
  /// This is a slope limit rather than tidiness. Two anchors 1 % apart describe
  /// a near-vertical line, and on that line an ambient flicker the sensor barely
  /// notices becomes the monitor jumping from dim to full. A tenth of the range
  /// is the flattest that is still expressive.
  public static let minimumSeparation = 0.1

  public init(lower: Anchor, upper: Anchor) {
    self.lower = lower
    self.upper = upper
  }

  /// Follow exactly, one to one. What a display starts on, because the first
  /// thing it should do is track — not apply a preference nobody expressed.
  public static let identity = FollowCurve(
    lower: Anchor(source: 0, target: 0),
    upper: Anchor(source: 1, target: 1)
  )

  public var isIdentity: Bool { self == .identity }

  /// Where this display belongs when the source display is at `source`.
  public func target(forSource source: Double) -> Double {
    let value = min(1, max(0, source))

    // Held rather than extrapolated at both ends — see the type comment.
    if value <= lower.source { return lower.target }
    if value >= upper.source { return upper.target }

    let span = upper.source - lower.source
    // `learn` maintains the separation, so this cannot normally happen. It is
    // still checked, because the alternative to a guard here is a division by
    // zero on a value that came off disk.
    guard span > 1e-9 else { return lower.target }

    let position = (value - lower.source) / span
    let interpolated = lower.target + position * (upper.target - lower.target)
    return min(1, max(0, interpolated))
  }

  /// Records that at `source`, this display should be at `target`.
  ///
  /// Called when someone adjusts a following display by hand. That is not a
  /// conflict to be corrected — it is the only reliable statement of intent the
  /// app ever gets, made at the one moment the person can see both the room and
  /// the screen. So it is taken as instruction: the anchor nearer this ambient
  /// level moves, the other stays, and the relationship at the far end of the
  /// range is left exactly as it was taught.
  public mutating func learn(source: Double, target: Double) {
    let anchor = Anchor(source: source, target: target)

    // Ties go to the lower anchor, which only matters at the exact midpoint.
    if abs(anchor.source - lower.source) <= abs(anchor.source - upper.source) {
      lower = anchor
      guard upper.source - lower.source < Self.minimumSeparation else { return }
      // Make room by moving the anchor that was not just taught — and if there
      // is no room above, give way below instead. The taught *target* is never
      // touched either way; only where it sits on the source axis.
      upper.source = min(1, lower.source + Self.minimumSeparation)
      if upper.source - lower.source < Self.minimumSeparation {
        lower.source = max(0, upper.source - Self.minimumSeparation)
      }
    } else {
      upper = anchor
      guard upper.source - lower.source < Self.minimumSeparation else { return }
      lower.source = max(0, upper.source - Self.minimumSeparation)
      if upper.source - lower.source < Self.minimumSeparation {
        upper.source = min(1, lower.source + Self.minimumSeparation)
      }
    }
  }

  /// Decoded by hand for the reason spelled out on `GlobalSettings.init(from:)`:
  /// a missing key must degrade to the default rather than throw, because a
  /// throw here takes every setting for this display with it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lower = try container.decodeIfPresent(Anchor.self, forKey: .lower) ?? Self.identity.lower
    upper = try container.decodeIfPresent(Anchor.self, forKey: .upper) ?? Self.identity.upper
  }
}
