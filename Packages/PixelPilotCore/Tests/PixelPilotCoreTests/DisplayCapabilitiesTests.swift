import Foundation
import Testing

@testable import PixelPilotCore

/// These cases are taken from an actual Samsung U32T1, which answers every query
/// it is given whether or not the feature exists. The heuristic that separates a
/// real control from a firmware stub is the difference between a working slider
/// and one that moves without effect.
@Suite("Display capabilities")
struct DisplayCapabilitiesTests {
  @Test("Real brightness and contrast are accepted")
  func acceptsRealControls() {
    #expect(DisplayCapabilities.classify(
      DDCReading(current: 100, maximum: 100), for: .luminance
    ).isUsable)

    #expect(DisplayCapabilities.classify(
      DDCReading(current: 50, maximum: 100), for: .contrast
    ).isUsable)
  }

  /// Observed on hardware: a monitor with no speakers reports volume 100 with a
  /// maximum of 65535.
  @Test("A 0xFFFF maximum is rejected", arguments: [
    VCPCode.audioSpeakerVolume, .audioMute, .luminance, .inputSource, .powerMode,
  ])
  func rejectsUninitialisedMaximum(vcp: VCPCode) {
    let support = DisplayCapabilities.classify(
      DDCReading(current: 1, maximum: 0xFFFF), for: vcp
    )
    #expect(!support.isUsable)
  }

  /// The specific trap this guard exists for: mute's garbage current value of 1
  /// is indistinguishable from a valid "muted" reading, so only the maximum
  /// gives the stub away.
  @Test("Mute is not accepted on a speakerless panel")
  func rejectsPhantomMute() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 1, maximum: 0xFFFF), for: .audioMute
    ).isUsable)

    #expect(DisplayCapabilities.classify(
      DDCReading(current: 1, maximum: 2), for: .audioMute
    ).isUsable)
  }

  @Test("Out-of-range enumerated values are rejected")
  func rejectsBadEnums() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 42, maximum: 2), for: .audioMute
    ).isUsable)

    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 9, maximum: 5), for: .powerMode
    ).isUsable)

    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 0, maximum: 14), for: .inputSource
    ).isUsable)
  }

  @Test("Enumerated controls keep their real values", arguments: [
    (VCPCode.powerMode, UInt16(1)), (.powerMode, 4), (.inputSource, 7), (.audioMute, 2),
  ])
  func acceptsValidEnums(vcp: VCPCode, current: UInt16) {
    let support = DisplayCapabilities.classify(
      DDCReading(current: current, maximum: 14), for: vcp
    )
    #expect(support.isUsable)
    #expect(support.reading?.current == current)
  }

  @Test("Continuous controls above the plausible ceiling are rejected")
  func rejectsWideContinuousRange() {
    #expect(DisplayCapabilities.classify(
      DDCReading(current: 500, maximum: 1000), for: .luminance
    ).isUsable, "1000 is unusual but within spec")

    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 500, maximum: 5000), for: .luminance
    ).isUsable)
  }

  @Test("A current value above its own maximum is rejected")
  func rejectsInconsistentReading() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 200, maximum: 100), for: .luminance
    ).isUsable)
  }

  @Test("A zero maximum is rejected")
  func rejectsZeroMaximum() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 0, maximum: 0), for: .contrast
    ).isUsable)
  }

  // MARK: - Persistence

  /// Capabilities are cached per display and re-read on later launches, so the
  /// encoding has to survive a round trip — including the VCP dictionary keys.
  @Test("Capabilities survive an encode/decode round trip")
  func codableRoundTrip() throws {
    let original = DisplayCapabilities(features: [
      .luminance: .supported(current: 100, maximum: 100),
      .audioSpeakerVolume: .implausible(current: 100, maximum: 0xFFFF, reason: "stub"),
      .contrast: .unsupported,
      .inputSource: .unreachable("timeout"),
    ])

    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(DisplayCapabilities.self, from: data)

    #expect(restored.features == original.features)
    #expect(restored.isUsable(.luminance))
    #expect(!restored.isUsable(.audioSpeakerVolume))
  }

  @Test("VCP keys encode as readable hex")
  func readableKeys() throws {
    let capabilities = DisplayCapabilities(features: [
      .luminance: .supported(current: 50, maximum: 100),
    ])
    let json = String(decoding: try JSONEncoder().encode(capabilities), as: UTF8.self)
    #expect(json.contains("0x10"))
  }

  @Test("An unprobed feature is not silently treated as usable")
  func unprobedIsNotUsable() {
    #expect(!DisplayCapabilities().isUsable(.luminance))
  }

  // MARK: - Colour

  @Test("A colour temperature spanning a real range is believed")
  func plausibleColorTemperature() {
    // 0...120 steps of 50 K above 3000 K — 3000 to 9000 K, which is what a
    // monitor's own menu offers.
    let support = DisplayCapabilities.classify(
      DDCReading(current: 70, maximum: 120), for: .colorTemperature
    )
    #expect(support.isUsable)
  }

  /// The register answers, correctly checksummed, with a number that would mean
  /// a colour temperature no object has. That is the whole "panels lie" problem
  /// in one reading.
  @Test("A colour temperature implying an absurd range is refused, with a reason")
  func implausibleColorTemperature() {
    let support = DisplayCapabilities.classify(
      DDCReading(current: 100, maximum: 900), for: .colorTemperature
    )
    guard case let .implausible(_, _, reason) = support else {
      Issue.record("expected implausible, got \(support)")
      return
    }
    #expect(reason.contains("K"))
    #expect(!support.isUsable)
  }

  @Test("A zero maximum is not a colour temperature control")
  func zeroMaximumColorTemperature() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 0, maximum: 0), for: .colorTemperature
    ).isUsable)
  }

  @Test("An increment outside the usable step range is refused")
  func implausibleIncrement() {
    #expect(DisplayCapabilities.classify(
      DDCReading(current: 50, maximum: 5000), for: .colorTemperatureIncrement
    ).isUsable)
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 0, maximum: 5000), for: .colorTemperatureIncrement
    ).isUsable)
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 30000, maximum: 40000), for: .colorTemperatureIncrement
    ).isUsable)
  }

  @Test("A colour preset of zero means nothing is selected, which cannot be true")
  func zeroColorPreset() {
    #expect(!DisplayCapabilities.classify(
      DDCReading(current: 0, maximum: 11), for: .selectColorPreset
    ).isUsable)
    #expect(DisplayCapabilities.classify(
      DDCReading(current: 5, maximum: 11), for: .selectColorPreset
    ).isUsable)
  }

  // MARK: - Gains

  @Test("Three gains sharing a maximum are a colour control")
  func completeGains() {
    let capabilities = DisplayCapabilities(features: [
      .redGain: .supported(current: 50, maximum: 100),
      .greenGain: .supported(current: 50, maximum: 100),
      .blueGain: .supported(current: 50, maximum: 100),
    ])
    #expect(capabilities.hasUsableGains)
  }

  /// A panel answering for red but not green is not exposing a colour control.
  /// Driving it would tint the picture with no way to put it back.
  @Test("A missing channel disqualifies the whole set")
  func incompleteGains() {
    let capabilities = DisplayCapabilities(features: [
      .redGain: .supported(current: 50, maximum: 100),
      .blueGain: .supported(current: 50, maximum: 100),
    ])
    #expect(!capabilities.hasUsableGains)
  }

  @Test("Gains on different scales are not three channels of one control")
  func mismatchedGainMaxima() {
    let capabilities = DisplayCapabilities(features: [
      .redGain: .supported(current: 50, maximum: 100),
      .greenGain: .supported(current: 50, maximum: 255),
      .blueGain: .supported(current: 50, maximum: 100),
    ])
    #expect(!capabilities.hasUsableGains)
  }

  @Test("A phantom channel disqualifies the set even though it answered")
  func phantomGain() {
    let capabilities = DisplayCapabilities(features: [
      .redGain: .supported(current: 50, maximum: 100),
      .greenGain: .implausible(current: 100, maximum: 0xFFFF, reason: "not implemented"),
      .blueGain: .supported(current: 50, maximum: 100),
    ])
    #expect(!capabilities.hasUsableGains)
  }
}
