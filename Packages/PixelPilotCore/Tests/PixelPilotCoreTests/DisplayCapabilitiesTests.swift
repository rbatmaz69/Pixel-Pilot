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
}
