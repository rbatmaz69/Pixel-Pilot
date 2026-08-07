import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Test patterns")
struct TestPatternTests {
  @Test("Every pattern says what it is and what to look for")
  func allPatternsAreDescribed() {
    for pattern in TestPattern.allCases {
      #expect(!pattern.title.isEmpty)
      #expect(!pattern.purpose.isEmpty)
      #expect(pattern.id == pattern.rawValue)
    }
  }

  /// The solids come first because a dead pixel makes everything below them
  /// moot, and the guided check walks them in declaration order.
  @Test("The solid colours come first")
  func solidsComeFirst() {
    let expected: [TestPattern] = [.white, .black, .red, .green, .blue]
    #expect(Array(TestPattern.allCases.prefix(5)) == expected)
  }

  /// **The test that stops a rename.** Raw values are storage: renaming a case
  /// compiles, decodes without complaint, and silently turns every stored
  /// verdict for that pattern into "never answered" on every machine.
  @Test("The stored names never change")
  func rawValuesArePinned() {
    #expect(
      TestPattern.allCases.map(\.rawValue) == [
        "white", "black", "red", "green", "blue",
        "greyRamp", "shadowSteps", "highlightSteps",
        "uniformityMid", "uniformityDark", "checkerboard",
      ]
    )
  }

  /// A bright speck on black, banding on the ramp, and a visible checkerboard
  /// are three different statements. One "3 problems found" would report them
  /// identically.
  @Test("Every pattern is classified, and the solids are the pixel tests")
  func problemClassPartitions() {
    let faults = TestPattern.allCases.filter { $0.problemClass == .pixelFault }
    #expect(faults == [.white, .black, .red, .green, .blue])
    #expect(TestPattern.allCases.filter { $0.problemClass == .configuration } == [.checkerboard])
    #expect(TestPattern.allCases.allSatisfy { ProblemClass.allCases.contains($0.problemClass) })
  }

  @Test("Furniture is inked against the pattern under it")
  func inkContrasts() {
    #expect(TestPattern.white.ink == .dark)
    #expect(TestPattern.uniformityMid.ink == .dark)
    #expect(TestPattern.black.ink == .light)
    #expect(TestPattern.uniformityDark.ink == .light)
  }
}

@Suite("Health reports")
struct HealthReportTests {
  private func report(
    _ verdicts: [TestPattern: HealthReport.PatternVerdict], defects: Int = 0
  ) -> HealthReport {
    var raw: [String: HealthReport.PatternVerdict] = [:]
    for (pattern, verdict) in verdicts { raw[pattern.rawValue] = verdict }
    return HealthReport(verdicts: raw, defectCount: defects)
  }

  private var allClean: [TestPattern: HealthReport.PatternVerdict] {
    Dictionary(uniqueKeysWithValues: TestPattern.allCases.map { ($0, .looksRight) })
  }

  @Test("An unanswered pattern reads as skipped rather than clean")
  func absentIsSkipped() {
    let empty = HealthReport()
    #expect(empty[.white] == .skipped)
    #expect(empty.answered.isEmpty)
    #expect(!empty.isComplete)
  }

  @Test("A full clean walk is clean")
  func cleanWalk() {
    #expect(report(allClean).overall == .clean)
  }

  /// Banding is what this panel is like. Nothing is broken and no setting will
  /// change it, so calling it a fault would send somebody looking for a fix
  /// that does not exist.
  @Test("Quality-only problems are not faults")
  func qualityProblemsAreCharacteristics() {
    var verdicts = allClean
    verdicts[.greyRamp] = .problem
    verdicts[.uniformityDark] = .problem
    #expect(report(verdicts).overall == .characteristics)
  }

  @Test("A flagged solid is a fault")
  func flaggedSolidIsAFault() {
    var verdicts = allClean
    verdicts[.black] = .problem
    #expect(report(verdicts).overall == .faults)
  }

  /// A mark outranks every verdict: somebody pointed at a specific spot on the
  /// glass, which is a stronger statement than "the screen looked fine".
  @Test("Any mark makes it a fault, however clean the answers were")
  func anyMarkIsAFault() {
    #expect(report(allClean, defects: 1).overall == .faults)
  }

  @Test("A half-finished walk is incomplete")
  func halfWalkIsIncomplete() {
    let verdicts = Dictionary(
      uniqueKeysWithValues: TestPattern.allCases.prefix(5).map { ($0, HealthReport.PatternVerdict.looksRight) }
    )
    let partial = report(verdicts)
    #expect(partial.overall == .incomplete)
    #expect(partial.answered.count == 5)
  }

  /// The deliberate asymmetry. Finding a dead pixel on the second pattern and
  /// stopping there is a *finished* check — the question was answered.
  @Test("A fault found early outranks not having finished")
  func faultOutranksIncompleteness() {
    let partial = report([.white: .looksRight, .black: .problem])
    #expect(!partial.isComplete)
    #expect(partial.overall == .faults)
  }

  @Test("The headline names what was found rather than counting it")
  func headlineNames() {
    #expect(report(allClean).headline.contains("looked right"))

    var flagged = allClean
    flagged[.greyRamp] = .problem
    #expect(report(flagged).headline.contains("grey ramp"))

    #expect(report(allClean, defects: 1).headline.contains("1 marked spot"))
    #expect(report(allClean, defects: 3).headline.contains("3 marked spots"))
  }

  @Test("Every verdict has something to show for it")
  func verdictsAreNamed() {
    for verdict in [HealthReport.Verdict.clean, .characteristics, .faults, .incomplete] {
      #expect(!verdict.displayName.isEmpty)
    }
  }

  @Test("A report round-trips through JSON")
  func roundTrip() throws {
    var verdicts = allClean
    verdicts[.black] = .problem
    let original = report(verdicts, defects: 2)

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(HealthReport.self, from: data)

    #expect(decoded.verdicts == original.verdicts)
    #expect(decoded.defectCount == 2)
    #expect(decoded.overall == .faults)
  }

  /// A verdict written by a later build must not take the whole report with it.
  @Test("An unknown verdict is dropped, and the rest survives")
  func unknownVerdictIsDropped() throws {
    let json = """
      {"date":0,"defectCount":0,
       "verdicts":{"white":"looksRight","black":"needsALongerLook"}}
      """
    let decoded = try JSONDecoder().decode(HealthReport.self, from: Data(json.utf8))
    #expect(decoded[.white] == .looksRight)
    #expect(decoded[.black] == .skipped)
  }

  @Test("A report with nothing in it decodes to an empty one")
  func emptyDecodes() throws {
    let decoded = try JSONDecoder().decode(HealthReport.self, from: Data("{}".utf8))
    #expect(decoded.verdicts.isEmpty)
    #expect(decoded.overall == .incomplete)
  }
}

@Suite("Health check session")
struct HealthCheckSessionTests {
  @Test("The walk starts at the first pattern and follows the declared order")
  func startsAtTheBeginning() {
    let session = HealthCheckSession()
    #expect(session.current == TestPattern.allCases.first)
    #expect(session.order == TestPattern.allCases)
    #expect(session.progress == (1, TestPattern.allCases.count))
    #expect(!session.isFinished)
  }

  @Test("Answering advances")
  func answeringAdvances() {
    var session = HealthCheckSession()
    session.answer(.looksRight)
    #expect(session.current == TestPattern.allCases[1])
    #expect(session.progress.step == 2)
  }

  /// So the answer and the marking that follows it happen on the same screen.
  @Test("Flagging records a problem without moving on")
  func flaggingStaysPut() {
    var session = HealthCheckSession()
    session.flagCurrent()
    #expect(session.current == TestPattern.allCases.first)
    #expect(session.verdicts[TestPattern.white.rawValue] == .problem)
  }

  @Test("Going back re-asks, and stops at the start")
  func goingBack() {
    var session = HealthCheckSession()
    session.answer(.looksRight)
    session.answer(.problem)
    session.back()
    #expect(session.current == TestPattern.allCases[1])

    session.back()
    session.back()
    #expect(session.current == TestPattern.allCases.first)
  }

  @Test("A finished walk has an answer for everything")
  func finishedWalk() {
    var session = HealthCheckSession()
    while !session.isFinished { session.answer(.looksRight) }
    #expect(session.current == nil)

    let finished = session.report(defectCount: 0)
    #expect(finished.isComplete)
    #expect(finished.overall == .clean)
    #expect(!finished.verdicts.values.contains(.skipped))
  }

  /// "Stopped after five" and "answered five of eleven" must be the same
  /// statement on disk as they are on screen.
  @Test("An abandoned walk marks the rest skipped rather than omitting them")
  func abandonedWalk() {
    var session = HealthCheckSession()
    session.answer(.looksRight)
    session.answer(.looksRight)

    let partial = session.report(defectCount: 0)
    #expect(partial.verdicts.count == TestPattern.allCases.count)
    #expect(partial.answered.count == 2)
    #expect(partial.overall == .incomplete)
  }

  @Test("Answering past the end changes nothing")
  func answeringPastTheEnd() {
    var session = HealthCheckSession()
    while !session.isFinished { session.answer(.looksRight) }
    let before = session
    session.answer(.problem)
    session.flagCurrent()
    #expect(session == before)
  }
}

@Suite("Repair plan")
struct RepairPlanTests {
  /// The whole point of eight rather than three: red, green and blue alone
  /// leave each channel off for two thirds of the cycle.
  @Test("The cycle works every sub-pixel equally")
  func everyChannelSwingsHalfTheTime() {
    for intensity in RepairPlan.Intensity.allCases {
      let cycle = RepairPlan.sequence(for: intensity)
      #expect(cycle.count == 8)
      let high = intensity.span.upperBound
      #expect(cycle.filter { $0.red == high }.count == 4)
      #expect(cycle.filter { $0.green == high }.count == 4)
      #expect(cycle.filter { $0.blue == high }.count == 4)
    }
  }

  @Test("Standard goes all the way, gentle never does")
  func intensitySpans() {
    for colour in RepairPlan.sequence(for: .standard) {
      #expect(colour.red == 0 || colour.red == 1)
      #expect(colour.green == 0 || colour.green == 1)
      #expect(colour.blue == 0 || colour.blue == 1)
    }
    for colour in RepairPlan.sequence(for: .gentle) {
      for channel in [colour.red, colour.green, colour.blue] {
        #expect(channel >= 0.25)
        #expect(channel <= 0.75)
      }
    }
  }

  /// Neighbouring marks running in lockstep would be a small local flash, which
  /// is the one thing the whole design is avoiding.
  @Test("Phase genuinely offsets the cycle, and the cycle repeats")
  func phaseAndPeriodicity() {
    let count = RepairPlan.corners.count
    for tick in 0 ..< 20 {
      #expect(
        RepairPlan.colour(at: tick, intensity: .standard)
          == RepairPlan.colour(at: tick + count, intensity: .standard)
      )
      #expect(
        RepairPlan.colour(at: tick, phase: 3, intensity: .standard)
          == RepairPlan.colour(at: tick + 3, intensity: .standard)
      )
    }
    // A negative tick is not reachable today, but the modulo has to be the
    // wrapping kind rather than Swift's remainder or it would crash if it ever
    // were.
    #expect(RepairPlan.colour(at: -1, intensity: .standard) == RepairPlan.corners.last)
  }

  /// A panel cannot show more transitions than it refreshes, so asking for more
  /// buys nothing and costs a torn pattern.
  @Test("The rate never exceeds what the panel refreshes at")
  func rateIsCappedByRefresh() {
    #expect(RepairPlan.fieldsPerSecond(refreshHz: 60, intensity: .standard) == 60)
    #expect(RepairPlan.fieldsPerSecond(refreshHz: 120, intensity: .standard) == 120)
    #expect(RepairPlan.fieldsPerSecond(refreshHz: 60, intensity: .gentle) == 3)
    // A panel that reports nothing is treated as 60 rather than as zero, which
    // would be a division by zero one line later.
    #expect(RepairPlan.fieldsPerSecond(refreshHz: 0, intensity: .standard) == 60)
    #expect(RepairPlan.fieldsPerSecond(refreshHz: 2, intensity: .gentle) == 2)
  }

  @Test("A cycle takes as long as its fields divided by the rate")
  func cycleDuration() {
    #expect(RepairPlan.cycleDuration(fields: 32, refreshHz: 64, intensity: .standard) == 0.5)
    // Three a second is the WCAG line, so a gentle field is never shorter than
    // a third of a second.
    let gentle = RepairPlan.cycleDuration(fields: 8, refreshHz: 120, intensity: .gentle)
    #expect(abs(gentle / 8 - 1.0 / 3) < 1e-9)
    #expect(RepairPlan.cycleDuration(fields: 0, refreshHz: 60, intensity: .standard) == 0)
  }

  @Test("Every option says what it is")
  func optionsAreDescribed() {
    for intensity in RepairPlan.Intensity.allCases {
      #expect(!intensity.displayName.isEmpty)
      #expect(!intensity.summary.isEmpty)
    }
    for style in RepairPlan.Style.allCases {
      #expect(!style.displayName.isEmpty)
      #expect(!style.summary.isEmpty)
    }
    #expect(RepairPlan.Duration.tenMinutes.seconds == 600)
    #expect(RepairPlan.Duration.oneHour.seconds == 3600)
    #expect(RepairPlan.Duration.untilStopped.seconds == nil)
  }
}
