import Foundation

/// What a walk through the test patterns found.
///
/// Kept as a value with no reference to a display, like `Preset` — the display
/// it belongs to is the `DisplayKey` it is stored under.
public struct HealthReport: Codable, Sendable, Equatable {
  public enum PatternVerdict: String, Codable, Sendable {
    case looksRight
    case problem
    /// Never answered. Distinct from `looksRight`, and the distinction is the
    /// point: a check abandoned after five patterns must not read as six clean
    /// screens.
    case skipped
  }

  /// A verdict rather than a score out of a hundred.
  ///
  /// A number would imply a measurement, and nothing here is measured — every
  /// input is a person saying whether a screen looked right to them. Four words
  /// that can be defended beat a figure that cannot.
  public enum Verdict: String, Codable, Sendable {
    case clean
    /// Nothing broken. The panel is being itself, and no setting will change it.
    case characteristics
    case faults
    case incomplete

    public var displayName: String {
      switch self {
      case .clean: "Looks clean"
      case .characteristics: "Nothing broken, but worth knowing"
      case .faults: "Problems found"
      case .incomplete: "Partly checked"
      }
    }
  }

  public var date: Date
  /// Keyed by `TestPattern.rawValue`, and a plain `[String: …]` on purpose.
  /// Swift encodes a dictionary whose key is a `RawRepresentable` enum as a
  /// flat array of alternating keys and values, and throws on a raw value it
  /// does not recognise — so `[TestPattern: PatternVerdict]` would be both ugly
  /// on disk and fragile the first time a pattern is added.
  public var verdicts: [String: PatternVerdict]
  /// The number of marks at the time of the check.
  ///
  /// Stored rather than derived so the card can still say what was found after
  /// the marks have been cleared, without claiming they are still there.
  public var defectCount: Int

  public init(
    date: Date = Date(),
    verdicts: [String: PatternVerdict] = [:],
    defectCount: Int = 0
  ) {
    self.date = date
    self.verdicts = verdicts
    self.defectCount = defectCount
  }

  public subscript(_ pattern: TestPattern) -> PatternVerdict {
    verdicts[pattern.rawValue] ?? .skipped
  }

  public var answered: [TestPattern] {
    TestPattern.allCases.filter { self[$0] != .skipped }
  }

  public var flagged: [TestPattern] {
    TestPattern.allCases.filter { self[$0] == .problem }
  }

  public var isComplete: Bool { answered.count == TestPattern.allCases.count }

  /// The one interesting derivation in this file.
  ///
  /// Note the asymmetry, which is deliberate: a pixel fault or any mark
  /// outranks incompleteness. Finding a dead pixel on the second pattern and
  /// stopping there is a *finished* check — the question was answered — not an
  /// abandoned one.
  public var overall: Verdict {
    let problems = flagged
    if defectCount > 0 || problems.contains(where: { $0.problemClass == .pixelFault }) {
      return .faults
    }
    if !isComplete { return .incomplete }
    return problems.isEmpty ? .clean : .characteristics
  }

  /// One line for the card, saying what was actually found rather than counting
  /// it. "Banding on the grey ramp" is an answer; "2 problems" is a prompt to go
  /// and look again.
  public var headline: String {
    let problems = flagged
    if defectCount > 0 {
      let marks = defectCount == 1 ? "1 marked spot" : "\(defectCount) marked spots"
      guard let first = problems.first else { return marks }
      return "\(marks), spotted on \(first.title.lowercased())"
    }
    if problems.isEmpty {
      return isComplete
        ? "All \(TestPattern.allCases.count) patterns looked right"
        : "\(answered.count) of \(TestPattern.allCases.count) patterns checked"
    }
    let named = problems.prefix(2).map { $0.title.lowercased() }.joined(separator: " and ")
    let rest = problems.count - min(2, problems.count)
    let tail = rest > 0 ? ", and \(rest) more" : ""
    return "Flagged on \(named)\(tail)"
  }

  /// Hand-written for the reason on `DisplaySettings.init(from:)`. Every key
  /// degrades: a report with no verdicts is an empty one, which `overall`
  /// already reads as `.incomplete`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    // A verdict written by a later build with a case this one has never heard
    // of would throw and take the whole report with it, so the dictionary is
    // decoded loosely and the unknown values are dropped one at a time.
    let raw = (try? container.decodeIfPresent([String: String].self, forKey: .verdicts)) ?? [:]
    verdicts = raw.compactMapValues(PatternVerdict.init(rawValue:))
    defectCount = try container.decodeIfPresent(Int.self, forKey: .defectCount) ?? 0
  }
}

/// A guided walk through the patterns, as a value.
///
/// Kept out of the controller so the sequencing can be tested without a screen
/// — the same split `AttentionPlan` makes from `AttentionController`.
public struct HealthCheckSession: Sendable, Equatable {
  public let order: [TestPattern]
  public private(set) var index: Int
  public private(set) var verdicts: [String: HealthReport.PatternVerdict]

  public init(order: [TestPattern] = TestPattern.allCases) {
    self.order = order
    index = 0
    verdicts = [:]
  }

  /// `nil` once the walk is past its last pattern.
  public var current: TestPattern? {
    order.indices.contains(index) ? order[index] : nil
  }

  public var isFinished: Bool { index >= order.count }

  /// One-based, for showing. "Step 0 of 11" helps nobody.
  public var progress: (step: Int, total: Int) {
    (min(index + 1, order.count), order.count)
  }

  public mutating func answer(_ verdict: HealthReport.PatternVerdict) {
    guard let pattern = current else { return }
    verdicts[pattern.rawValue] = verdict
    index += 1
  }

  /// Records a problem without advancing — so the answer and the marking that
  /// follows it happen on the same screen.
  public mutating func flagCurrent() {
    guard let pattern = current else { return }
    verdicts[pattern.rawValue] = .problem
  }

  public mutating func back() {
    guard index > 0 else { return }
    index -= 1
  }

  /// Patterns never reached come back `.skipped` rather than absent, so
  /// "stopped after five" and "answered five of eleven" are the same statement
  /// on disk as they are on screen.
  public func report(defectCount: Int, date: Date = Date()) -> HealthReport {
    var filled = verdicts
    for pattern in order where filled[pattern.rawValue] == nil {
      filled[pattern.rawValue] = .skipped
    }
    return HealthReport(date: date, verdicts: filled, defectCount: defectCount)
  }
}
