import Foundation

/// What the stuck-pixel exerciser puts on the screen, and how fast.
///
/// **The theory, stated plainly because the interface repeats it.** A stuck
/// cell is one whose liquid crystal is not relaxing to the voltage it is being
/// given. Swinging that voltage hard between extremes, many times a second,
/// sometimes frees it. There is no manufacturer behind this and no study; it is
/// folk practice that works often enough to be worth ten minutes and not often
/// enough to promise anything. It does nothing at all for a dead pixel, and the
/// interface says so rather than letting the button imply otherwise.
///
/// Everything here is arithmetic over colours as numbers. Nothing in this file
/// draws, and nothing in it knows about a layer — that is `RepairSurfaceView`'s
/// job, and keeping the split is what lets the sequence be tested.
public enum RepairPlan {
  /// A colour as three sRGB channels, 0…1. Not a `Color`: this package draws
  /// nothing.
  public struct Channels: Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
      self.red = red
      self.green = green
      self.blue = blue
    }
  }

  /// How hard the cells are worked.
  public enum Intensity: String, Codable, Sendable, CaseIterable {
    /// Every channel at 0 or full, changing once per display frame. The actual
    /// exercise.
    case standard
    /// Three changes a second, between 0.25 and 0.75 rather than 0 and 1.
    ///
    /// For Reduce Motion and for anyone who would rather not look at the first
    /// one. Not a placebo — the cells still swing — but plainly a weaker
    /// exercise, and the sheet says that too.
    case gentle

    public var displayName: String {
      switch self {
      case .standard: "Standard"
      case .gentle: "Gentle"
      }
    }

    public var summary: String {
      switch self {
      case .standard:
        "Full swing, changed every frame. The strongest exercise the panel can be given."
      case .gentle:
        "Three changes a second, and never all the way to black or white. "
          + "Easier to be in the room with, and a weaker exercise for it."
      }
    }

    /// The range each channel moves between.
    public var span: ClosedRange<Double> {
      switch self {
      case .standard: 0 ... 1
      case .gentle: 0.25 ... 0.75
      }
    }
  }

  /// What a full-screen pass looks like. Regional passes are always cube
  /// corners per region, so this only applies when there is nothing marked.
  public enum Style: String, Codable, Sendable, CaseIterable {
    /// Every block of the screen independently at a cube corner, a new field
    /// each frame.
    ///
    /// The default, and the reason is worth having in the source rather than
    /// only in the interface. Cycling the *whole* screen red → green → blue at
    /// speed — what the stuck-pixel websites do — is also a textbook
    /// photosensitive-seizure stimulus: a large-area, high-contrast, saturated
    /// flash in the 3–60 Hz band. You cannot both swing every sub-pixel across
    /// the whole panel and avoid a large-area flash; those are the same event
    /// described twice.
    ///
    /// Noise resolves it. Each pixel still spends half its time at zero and
    /// half at full on every channel, so the exercise is identical — but
    /// because neighbouring blocks are uncorrelated, the screen's average
    /// luminance stays flat and there is no coherent flash to trigger anything.
    case noise
    /// The whole screen through full-saturation colours, as the websites do it.
    ///
    /// Offered because it is what people came for and because familiarity is
    /// worth something, never as the default, and never without the warning.
    case classic

    public var displayName: String {
      switch self {
      case .noise: "Colour noise"
      case .classic: "Classic colour cycle"
      }
    }

    public var summary: String {
      switch self {
      case .noise:
        "Random colour at full swing, changed every frame. It exercises the same cells "
          + "as the flashing the repair sites use, without a screen-sized flash."
      case .classic:
        "The whole screen through solid colours, the way the repair websites do it. "
          + "That is a large, fast, high-contrast flash — pick the noise above if "
          + "there is any doubt."
      }
    }
  }

  public enum Duration: String, Codable, Sendable, CaseIterable {
    case tenMinutes
    case oneHour
    case untilStopped

    /// `nil` for `untilStopped`.
    public var seconds: Double? {
      switch self {
      case .tenMinutes: 600
      case .oneHour: 3600
      case .untilStopped: nil
      }
    }

    public var displayName: String {
      switch self {
      case .tenMinutes: "10 minutes"
      case .oneHour: "1 hour"
      case .untilStopped: "Until I stop it"
      }
    }
  }

  /// The eight corners of the RGB cube.
  ///
  /// The whole point, and the reason it is eight rather than three: every
  /// sub-pixel spends exactly half of these at zero and half at full. No
  /// shorter sequence does that for all three channels at once — red, green,
  /// blue alone leaves each channel off for two thirds of the cycle.
  public static let corners: [Channels] = [
    Channels(red: 0, green: 0, blue: 0),
    Channels(red: 1, green: 0, blue: 0),
    Channels(red: 0, green: 1, blue: 0),
    Channels(red: 0, green: 0, blue: 1),
    Channels(red: 1, green: 1, blue: 0),
    Channels(red: 1, green: 0, blue: 1),
    Channels(red: 0, green: 1, blue: 1),
    Channels(red: 1, green: 1, blue: 1),
  ]

  /// The cube corners mapped into the intensity's span.
  public static func sequence(for intensity: Intensity) -> [Channels] {
    let span = intensity.span
    let low = span.lowerBound
    let high = span.upperBound
    return corners.map {
      Channels(
        red: $0.red > 0.5 ? high : low,
        green: $0.green > 0.5 ? high : low,
        blue: $0.blue > 0.5 ? high : low
      )
    }
  }

  /// The colour a region shows on a given tick.
  ///
  /// Deterministic so it can be tested, and so two regions on screen can be
  /// deliberately put out of phase with each other — neighbouring marks running
  /// in lockstep would be a small local flash, which is the one thing this
  /// whole design is avoiding.
  public static func colour(at tick: Int, phase: Int = 0, intensity: Intensity) -> Channels {
    let all = sequence(for: intensity)
    let index = ((tick + phase) % all.count + all.count) % all.count
    return all[index]
  }

  /// WCAG 2.3.1 draws its line at more than three flashes in any one second
  /// over a large area. Borrowed rather than invented, and it is the whole
  /// reason `.gentle` runs at the rate it does.
  public static let gentleFieldsPerSecond: Double = 3

  /// How many fields a second the exercise should actually run at.
  ///
  /// The ceiling is not a preference: a display cannot show more transitions
  /// than it refreshes, so asking for 240 changes a second on a 60 Hz panel
  /// buys nothing and costs a torn, aliased pattern instead of a clean swing.
  public static func fieldsPerSecond(refreshHz: Double, intensity: Intensity) -> Double {
    let refresh = refreshHz > 0 ? refreshHz : 60
    switch intensity {
    case .standard: return refresh
    case .gentle: return min(gentleFieldsPerSecond, refresh)
    }
  }

  /// How long one pass through `fields` fields should take, for handing to a
  /// keyframe animation as its duration.
  public static func cycleDuration(
    fields: Int, refreshHz: Double, intensity: Intensity
  ) -> Double {
    guard fields > 0 else { return 0 }
    return Double(fields) / fieldsPerSecond(refreshHz: refreshHz, intensity: intensity)
  }
}
