import CoreGraphics
import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Attention")
struct AttentionTests {
  private let displayA: CGDirectDisplayID = 1
  private let displayB: CGDirectDisplayID = 2
  private let displayC: CGDirectDisplayID = 3

  private func candidates(
    _ ids: [CGDirectDisplayID], participating: Set<CGDirectDisplayID>? = nil
  ) -> [AttentionPlan.Candidate] {
    ids.map { id in
      AttentionPlan.Candidate(
        displayID: id, participates: participating?.contains(id) ?? true
      )
    }
  }

  private var on: AttentionSettings {
    var settings = AttentionSettings()
    settings.isEnabled = true
    settings.amount = 0.4
    return settings
  }

  @Test("A fresh installation does nothing")
  func offByDefault() {
    let settings = AttentionSettings()
    #expect(!settings.isEnabled)

    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: displayA, settings: settings
    )
    #expect(veils.values.allSatisfy { $0 == 1.0 })
  }

  @Test("The focused screen stays and the others sink")
  func unfocusedSink() {
    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB, displayC]), focused: displayB, settings: on
    )

    #expect(veils[displayB] == 1.0)
    #expect(veils[displayA] == on.veil)
    #expect(veils[displayC] == on.veil)
    #expect(abs((veils[displayA] ?? 0) - 0.6) < 1e-12)
  }

  /// The lockout case. Nil from both is a normal answer — no focused window and
  /// a pointer on a screen we do not know about — and veiling everything
  /// because nobody could be found is the failure where the user cannot see
  /// what to click to undo it.
  @Test("Nothing to go on means nothing sinks")
  func noAnswerVeilsNothing() {
    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: nil, pointer: nil, settings: on
    )
    #expect(veils.values.allSatisfy { $0 == 1.0 })
  }

  /// The bug this fallback was added for: clicking a screen's desktop makes the
  /// Finder frontmost with no focused window, so without a second answer that
  /// click lifts every veil and the feature looks like it does nothing.
  @Test("With no focused window the pointer answers instead")
  func pointerIsTheFallback() {
    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: nil, pointer: displayB, settings: on
    )

    #expect(veils[displayB] == 1.0)
    #expect(veils[displayA] == on.veil)
  }

  @Test("A focused window wins over the pointer")
  func focusBeatsPointer() {
    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: displayA, pointer: displayB, settings: on
    )

    #expect(veils[displayA] == 1.0, "the window being typed in, not where the mouse was left")
    #expect(veils[displayB] == on.veil)
  }

  /// A display that is not in the list is the same situation as none at all: it
  /// is about to be pruned, or it never belonged to us. True of either answer.
  @Test("A display we do not know about is not an answer")
  func unknownDisplayIsNotAnAnswer() {
    #expect(AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: 99, settings: on
    ).values.allSatisfy { $0 == 1.0 })

    // And an unknown focus still falls through to a pointer that is known.
    let fallen = AttentionPlan.veils(
      for: candidates([displayA, displayB]), focused: 99, pointer: displayA, settings: on
    )
    #expect(fallen[displayA] == 1.0)
    #expect(fallen[displayB] == on.veil)
  }

  @Test("One display never sinks")
  func singleDisplayNeverSinks() {
    let veils = AttentionPlan.veils(for: candidates([displayA]), focused: displayA, settings: on)
    #expect(veils == [displayA: 1.0])

    // Nor when it is somehow not the focused one.
    let orphan = AttentionPlan.veils(for: candidates([displayA]), focused: nil, settings: on)
    #expect(orphan == [displayA: 1.0])
  }

  @Test("A display that has opted out stays where it was put")
  func optedOutStays() {
    let veils = AttentionPlan.veils(
      for: candidates([displayA, displayB], participating: [displayA]),
      focused: displayA,
      settings: on
    )

    #expect(veils[displayA] == 1.0)
    #expect(veils[displayB] == 1.0, "opted out means it does not sink, even unfocused")
  }

  /// Every candidate must appear in the answer, including the ones that stay at
  /// 1. A display left out is a display whose veil never gets lifted.
  @Test("Every display is answered for, not just the ones that sink")
  func answersForEveryDisplay() {
    for focused: CGDirectDisplayID? in [displayA, nil] {
      for settings in [on, AttentionSettings()] {
        let veils = AttentionPlan.veils(
          for: candidates([displayA, displayB, displayC]), focused: focused, settings: settings
        )
        #expect(Set(veils.keys) == [displayA, displayB, displayC])
      }
    }
  }

  @Test("The amount is clamped on the way to a veil")
  func amountIsClamped() {
    var wild = AttentionSettings()
    wild.isEnabled = true

    wild.amount = 5
    #expect(wild.veil == 1 - AttentionSettings.amountRange.upperBound)

    wild.amount = -5
    #expect(wild.veil == 1 - AttentionSettings.amountRange.lowerBound)

    // And at its strongest it is still a long way from dark, which is what
    // stops this from becoming a way to lose a screen.
    wild.amount = AttentionSettings.amountRange.upperBound
    #expect(wild.veil > GammaRamp.minimumFraction)
  }

  @Test("Settings survive a round trip, and a payload missing one keeps the other")
  func roundTrips() throws {
    let data = try JSONEncoder().encode(on)
    #expect(try JSONDecoder().decode(AttentionSettings.self, from: data) == on)

    let partial = Data(#"{"isEnabled":true}"#.utf8)
    let decoded = try JSONDecoder().decode(AttentionSettings.self, from: partial)
    #expect(decoded.isEnabled)
    #expect(decoded.amount == AttentionSettings().amount)
  }
}
