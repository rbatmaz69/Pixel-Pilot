import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Control availability")
struct ControlAvailabilityTests {
  /// The shape every other test varies one argument of: an ordinary external
  /// monitor that has finished probing and is being driven over DDC.
  private func brightness(
    isReady: Bool = true,
    isProbing: Bool = false,
    hasDDCChannel: Bool = true,
    isBuiltin: Bool = false,
    strategy: BrightnessStrategy = .ddc
  ) -> ControlBlock? {
    ControlAvailability.brightness(
      isReady: isReady,
      isProbing: isProbing,
      hasDDCChannel: hasDDCChannel,
      isBuiltin: isBuiltin,
      strategy: strategy
    )
  }

  @Test("A working DDC monitor says nothing")
  func workingMonitorIsSilent() {
    #expect(brightness() == nil)
  }

  @Test("Probing comes before every other answer")
  func probingWinsFirst() {
    // Deliberately given three other things to complain about. Until the probe
    // lands, none of them are known to be true.
    #expect(brightness(isReady: false, hasDDCChannel: false, strategy: .gamma) == .stillProbing)
  }

  @Test("A re-probe comes before the answers it is about to change")
  func reprobingWinsSecond() {
    #expect(brightness(isProbing: true, strategy: .gamma) == .reprobing)
  }

  @Test("No transport is a warning, not a note")
  func missingChannelIsAWarning() {
    #expect(brightness(hasDDCChannel: false) == .noDDCChannel)
    #expect(ControlBlock.noDDCChannel.level == .warn)
  }

  @Test("Gamma on an external panel is worth saying")
  func gammaIsReported() {
    #expect(brightness(strategy: .gamma) == .softwareDimming)
    #expect(ControlBlock.softwareDimming.level == .info)
  }

  /// The built-in panel has no DDC channel by definition and macOS dims it in
  /// its own way. Reporting either would mean every MacBook opening the app to
  /// a finding about itself.
  @Test("The built-in panel is exempt from both hardware complaints")
  func builtinIsExempt() {
    #expect(brightness(hasDDCChannel: false, isBuiltin: true, strategy: .native) == nil)
    #expect(brightness(hasDDCChannel: false, isBuiltin: true, strategy: .gamma) == nil)
  }

  /// It still has to say when it is not ready, though — that one is true of any
  /// display and is what disables the slider.
  @Test("The built-in panel still reports probing")
  func builtinStillProbes() {
    #expect(brightness(isReady: false, isBuiltin: true, strategy: .native) == .stillProbing)
  }

  @Test("Contrast follows what the panel offered")
  func contrastFollowsCapabilities() {
    let usable = DisplayCapabilities(features: [.contrast: .supported(current: 50, maximum: 100)])
    #expect(ControlAvailability.contrast(capabilities: usable) == nil)

    #expect(ControlAvailability.contrast(capabilities: nil) == .noContrastControl)
    #expect(
      ControlAvailability.contrast(
        capabilities: DisplayCapabilities(features: [.contrast: .unsupported])
      ) == .noContrastControl
    )
    // Answered, but with something we cannot drive — the same as not offered.
    #expect(
      ControlAvailability.contrast(
        capabilities: DisplayCapabilities(
          features: [.contrast: .implausible(current: 0, maximum: 0, reason: "zero range")]
        )
      ) == .noContrastControl
    )
  }

  @Test("Volume is blocked only when there is nothing to drive")
  func volumeFollowsRoute() {
    #expect(ControlAvailability.volume(route: .displaySpeakers) == nil)
    #expect(ControlAvailability.volume(route: .system) == nil)
    #expect(ControlAvailability.volume(route: .unavailable) == .noVolumePath)
  }

  @Test("Every block says something at both lengths")
  func everyBlockIsDescribed() {
    for block in ControlBlock.allCases {
      #expect(!block.short.isEmpty)
      #expect(!block.explanation.isEmpty)
      // The short form is a clause, not a sentence — it is read as the tail of
      // a line under a display's name. Only the first letter is checked:
      // "not answering on DDC" has to keep its acronym.
      #expect(!block.short.hasSuffix("."))
      #expect(block.short.first?.isUppercase == false)
    }
  }

  @Test("Severity orders rather than counts")
  func levelsAreOrdered() {
    #expect(StatusLevel.ok < .info)
    #expect(StatusLevel.info < .warn)
    #expect(StatusLevel.warn < .bad)
    #expect(max(StatusLevel.info, .warn) == .warn)
  }
}
