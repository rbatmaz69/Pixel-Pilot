import CoreGraphics
import Foundation

/// A spot on a display somebody has marked as wrong.
///
/// Marked by hand rather than detected, and that is not a shortcut standing in
/// for something better. Finding a dead pixel means reading the screen back,
/// which means screen-recording permission — a permission this app does not ask
/// for and should not start asking for over a marker. The eye in front of the
/// panel is already the best instrument available, and it is already there.
public struct PixelDefect: Codable, Sendable, Equatable, Hashable, Identifiable {
  /// Stuck and dead are not two words for the same thing, and the difference is
  /// the whole reason the repair button can be honest about what it does.
  ///
  /// A **stuck** cell is lit and will not change: its liquid crystal is not
  /// relaxing to the voltage it is being given. Driving it hard sometimes frees
  /// it. A **dead** one never lights: its transistor is not switching, and no
  /// picture on the screen reaches a transistor.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case stuck
    case dead
    case unsure

    public var displayName: String {
      switch self {
      case .stuck: "Stuck"
      case .dead: "Dead"
      case .unsure: "Not sure"
      }
    }

    /// Whether exercising this has any theory behind it.
    public var isWorthExercising: Bool { self != .dead }

    /// The likely kind, from the pattern it was spotted on.
    ///
    /// Nobody standing in front of a black screen wants to be asked a taxonomy
    /// question; what they just saw already answers it. On black, something is
    /// lit that should not be — stuck. On white or a primary, something is dark
    /// that should be lit — dead, or a dead sub-pixel. On the rest, the mark is
    /// about the panel rather than about a pixel, so it stays unsure.
    ///
    /// A guess, and often wrong, which is why `S` and `D` exist on the overlay
    /// to correct it.
    public static func likely(spottedOn pattern: TestPattern?) -> Kind {
      switch pattern {
      case .black: .stuck
      case .white, .red, .green, .blue: .dead
      default: .unsure
      }
    }
  }

  public let id: UUID
  public var region: NormalisedRect
  public var kind: Kind
  /// `TestPattern.rawValue` rather than the enum: a mark placed by a later
  /// build on a pattern this one has never heard of must still decode, and must
  /// still show.
  public var spottedOn: String?
  public var date: Date

  public init(
    id: UUID = UUID(),
    region: NormalisedRect,
    kind: Kind,
    spottedOn: TestPattern?,
    date: Date = Date()
  ) {
    self.id = id
    self.region = region
    self.kind = kind
    self.spottedOn = spottedOn?.rawValue
    self.date = date
  }

  public var pattern: TestPattern? { spottedOn.flatMap(TestPattern.init(rawValue:)) }

  /// Hand-written for the reason on `DisplaySettings.init(from:)`.
  ///
  /// `region` is the one key allowed to throw, and deliberately: a mark with no
  /// place is not a degraded mark, it is nothing. `DisplaySettings` wraps the
  /// whole array in `try?`, so the cost of that throw is this display's marks
  /// and not this display's settings.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    region = try container.decode(NormalisedRect.self, forKey: .region)
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .unsure
    spottedOn = try container.decodeIfPresent(String.self, forKey: .spottedOn)
    date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
  }
}

/// Operations over a display's set of marks.
///
/// A namespace of free functions rather than methods on an array wrapper, for
/// the same reason `AttentionPlan` is one: every one of these is a pure
/// function of its inputs, and keeping them that way is what lets them be
/// tested without a screen.
public enum PixelDefects {
  /// The topmost mark under a point, or none.
  ///
  /// **Last wins**, matching draw order. Without that rule, clicking a mark
  /// drawn on top of another removes the one underneath — which looks like the
  /// click missed, so it gets repeated, and now two marks are gone.
  public static func hitTest(
    _ defects: [PixelDefect], at point: CGPoint, tolerance: Double = 0
  ) -> PixelDefect? {
    defects.last { $0.region.contains(point, tolerance: tolerance) }
  }

  /// "2 stuck, 1 dead". Empty when there are none, so the caller can decide
  /// whether saying nothing is better than saying zero.
  public static func summary(_ defects: [PixelDefect]) -> String {
    let counts = Kind.allCasesInReportOrder.compactMap { kind -> String? in
      let count = defects.filter { $0.kind == kind }.count
      guard count > 0 else { return nil }
      return "\(count) \(kind.displayName.lowercased())"
    }
    return counts.joined(separator: ", ")
  }

  /// The marks a repair pass has any theory about. A screen of dead pixels
  /// exercises nothing, and the sheet says so rather than running for ten
  /// minutes to no purpose.
  public static func worthExercising(_ defects: [PixelDefect]) -> [PixelDefect] {
    defects.filter { $0.kind.isWorthExercising }
  }

  /// The pattern most marks were spotted on, for reopening the overlay where
  /// they can actually be seen. Reopening a set of marks found on black over a
  /// white screen would show crop marks around nothing.
  public static func mostCommonPattern(_ defects: [PixelDefect]) -> TestPattern? {
    var tally: [TestPattern: Int] = [:]
    for defect in defects.compactMap(\.pattern) {
      tally[defect, default: 0] += 1
    }
    // Ties broken by declaration order rather than by dictionary order, so the
    // same set of marks always reopens on the same pattern.
    return TestPattern.allCases
      .filter { tally[$0] != nil }
      .max { (tally[$0] ?? 0) < (tally[$1] ?? 0) }
  }

  private typealias Kind = PixelDefect.Kind
}

extension PixelDefect.Kind {
  /// Worst first, so a summary leads with the thing that cannot be fixed.
  fileprivate static let allCasesInReportOrder: [Self] = [.stuck, .dead, .unsure]
}
