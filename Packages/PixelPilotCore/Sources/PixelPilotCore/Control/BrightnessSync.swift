import Foundation

/// Moving several displays together while keeping the difference between them.
///
/// The whole difficulty is at the ends, and it is not obvious until it has
/// happened. A display sitting 20 % below the master hits zero first; if the
/// offsets are then re-derived from what the displays are *currently* at, that
/// display's offset has quietly become zero too, and on the way back up the
/// spread the user set has been destroyed. It cannot be recovered, because
/// nothing recorded it.
///
/// So the offsets are captured once, when the group is armed, and never
/// re-derived. Clamping happens on the way out only. Drive the master to zero
/// and back and every display returns to exactly where it started.
public enum BrightnessSync {
  /// Captures how far each display sits from the master. Call once, when the
  /// group is turned on.
  public static func offsets(
    levels: [DisplayKey: Double], master: Double
  ) -> [DisplayKey: Double] {
    levels.mapValues { $0 - master }
  }

  /// Where each display should be for a given master value.
  ///
  /// Clamped here and nowhere else — the offsets themselves stay untouched, so
  /// a display parked at an end still knows where it belongs.
  public static func levels(
    master: Double, offsets: [DisplayKey: Double]
  ) -> [DisplayKey: Double] {
    offsets.mapValues { min(1, max(0, master + $0)) }
  }

  /// A sensible master for a group that is being armed: the average of what the
  /// displays are already at.
  ///
  /// Using one display's value instead would make arming the group jump every
  /// other display, which is a surprising thing for a switch labelled "keep
  /// these together" to do.
  public static func suggestedMaster(levels: [DisplayKey: Double]) -> Double {
    guard !levels.isEmpty else { return 1 }
    return levels.values.reduce(0, +) / Double(levels.count)
  }
}
