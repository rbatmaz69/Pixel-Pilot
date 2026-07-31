import Foundation

/// Where a slider should give a small tug back.
///
/// The arithmetic lives here rather than in the control for one reason: it is
/// the only part of a detent that can be *wrong*. Whether the handle squashes
/// and the trackpad ticks is a matter of taste and can be judged by using it;
/// whether a detent is entered once, at the right place, at a distance that
/// feels the same on a 200 pt and a 600 pt slider is a matter of fact.
///
/// A detent here is felt, never enforced. Nothing in this file rounds a value
/// to a detent, and the control must not either — snapping would quantise the
/// one property `ExpressiveSlider` promises to keep exact, the handle's
/// position under the pointer, and would make fine adjustment impossible on a
/// control whose whole job is fine adjustment.
public enum SliderDetents {
  /// The default marks: the ends, the quarters, and the middle.
  public static let quarters: [Double] = [0, 0.25, 0.5, 0.75, 1]

  /// How close to a detent counts as being on it, expressed as a fraction of
  /// the track.
  ///
  /// Derived from a distance in points rather than fixed, so the detent feels
  /// the same width whatever the slider's width happens to be. A fixed
  /// fractional tolerance would be twice as easy to hit in the menu bar panel
  /// as in the main window, which reads as the two controls behaving
  /// differently.
  ///
  /// Returns zero for a track with no room in it, which `nearest(to:…)` then
  /// treats as "no detent is reachable" rather than "every detent is".
  public static func tolerance(points: Double, travel: Double) -> Double {
    guard travel > 0, points > 0 else { return 0 }
    return min(1, points / travel)
  }

  /// The detent `position` is currently within, or `nil`.
  ///
  /// Callers latch the result and act only on a change, so that holding the
  /// pointer inside a detent gives one tick rather than one per frame.
  ///
  /// - Parameters:
  ///   - position: Where the handle is, as a 0...1 fraction of the track.
  ///   - detents: Marks as 0...1 fractions. Values outside that range can never
  ///     be entered, and are ignored rather than treated as an error — a caller
  ///     computing detents from a value range should not have to filter them.
  ///   - tolerance: Half-width of a detent, as a fraction of the track.
  public static func nearest(
    to position: Double, among detents: [Double], tolerance: Double
  ) -> Double? {
    guard tolerance > 0, !detents.isEmpty else { return nil }

    var best: Double?
    var bestDistance = Double.infinity
    for detent in detents where (0 ... 1).contains(detent) {
      let distance = abs(detent - position)
      guard distance <= tolerance else { continue }
      // Distance decides, and an exact tie goes to the lower detent. Without
      // that second clause a position exactly between two marks would resolve
      // by array order, and the same drag would tick differently depending on
      // how a call site happened to list its detents.
      let isBetter = distance < bestDistance
        || (distance == bestDistance && detent < (best ?? .infinity))
      guard isBetter else { continue }
      best = detent
      bestDistance = distance
    }
    return best
  }
}
