import Foundation
import Testing

@testable import PixelPilotCore

@Suite("VCP scanner")
struct VCPScannerTests {
  /// The case the whole scanner exists for. This is the exact reading the
  /// Samsung U32T1 returns for audio volume it does not implement: a
  /// well-formed reply that a naive "did it answer?" test would accept.
  @Test("A 0xFFFF maximum is a phantom, not a control")
  func detectsPhantomMaximum() {
    let classification = VCPScanner.classify(DDCReading(current: 100, maximum: 0xFFFF))
    guard case let .phantom(_, _, reason) = classification else {
      Issue.record("expected phantom, got \(classification)")
      return
    }
    #expect(reason.contains("0xFFFF"))
  }

  @Test("A zero maximum is a phantom too")
  func detectsZeroMaximum() {
    #expect(!VCPScanner.classify(DDCReading(current: 0, maximum: 0)).isLive)
  }

  /// Two fields that cannot describe the same control.
  @Test("A current value above the maximum is a phantom")
  func detectsInconsistentReading() {
    #expect(!VCPScanner.classify(DDCReading(current: 200, maximum: 100)).isLive)
  }

  /// The known-good counterpart: brightness on the same panel.
  @Test("A plausible range is live")
  func detectsLiveRegister() {
    let classification = VCPScanner.classify(DDCReading(current: 60, maximum: 100))
    #expect(classification.isLive)
  }

  @Test("A declined feature is absent, not a phantom")
  func declinedFeatureIsAbsent() {
    let classification = VCPScanner.classify(DDCError.unsupportedFeature(.audioSpeakerVolume))
    guard case let .absent(reason) = classification else {
      Issue.record("expected absent, got \(classification)")
      return
    }
    #expect(reason.contains("declined"))
  }

  @Test("A scan covers every code exactly once")
  func scansAllCodes() {
    let transport = ScriptedTransport(readings: [:])
    let results = VCPScanner.scan(transport: transport, timing: .default)
    #expect(results.count == 256)
    #expect(Set(results.map(\.code)).count == 256)
  }

  @Test("Declared codes are marked as such")
  func marksDeclaredCodes() {
    let transport = ScriptedTransport(readings: [0x10: DDCReading(current: 60, maximum: 100)])
    let results = VCPScanner.scan(transport: transport, declared: [0x10], timing: .default)

    let brightness = results.first { $0.code == 0x10 }
    #expect(brightness?.isDeclared == true)
    #expect(brightness?.classification.isLive == true)
    #expect(results.first { $0.code == 0x12 }?.isDeclared == false)
  }

  /// An undeclared live register with a volume-shaped range is the whole point
  /// of scanning — it must surface as a candidate.
  @Test("Undeclared registers with a plausible range become candidates")
  func findsUndeclaredCandidates() {
    let transport = ScriptedTransport(readings: [
      0x10: DDCReading(current: 60, maximum: 100),      // declared, not audio
      0xE4: DDCReading(current: 30, maximum: 100),      // undeclared, volume-shaped
      0x62: DDCReading(current: 100, maximum: 0xFFFF),  // phantom
    ])
    let results = VCPScanner.scan(transport: transport, declared: [0x10], timing: .default)
    let candidates = VCPScanner.audioCandidates(in: results)

    #expect(candidates.contains { $0.code == 0xE4 })
    #expect(!candidates.contains { $0.code == 0x62 }, "a phantom is never a candidate")
    #expect(!candidates.contains { $0.code == 0x10 }, "a declared non-audio control is not one either")
  }

  /// The analog geometry group all reports 0–100 ranges and survives in the
  /// firmware of digital panels driving nothing. Proposing those as audio
  /// candidates sends anyone reading the scan down a dead end.
  @Test("Documented controls are not candidates, whatever their range")
  func excludesDocumentedControls() {
    let transport = ScriptedTransport(readings: [
      0x0E: DDCReading(current: 50, maximum: 100), // Clock
      0x20: DDCReading(current: 0, maximum: 100),  // Horizontal Position
      0x30: DDCReading(current: 0, maximum: 100),  // Vertical Position
      0x3E: DDCReading(current: 50, maximum: 100), // Clock Phase
    ])
    let results = VCPScanner.scan(transport: transport, timing: .default)
    #expect(VCPScanner.audioCandidates(in: results).isEmpty)
  }
}

@Suite("Write probe")
struct WriteProbeTests {
  /// The guard that matters most. A stray write here factory-resets the display
  /// or switches it to an input that takes the picture — and the DDC channel
  /// with it, leaving no way back in software.
  @Test("Forbidden codes are never written")
  func refusesForbiddenCodes() {
    for code in WriteProbe.forbidden {
      let transport = ScriptedTransport(readings: [code: DDCReading(current: 1, maximum: 5)])
      let outcome = WriteProbe.probe(VCPCode(rawValue: code), transport: transport)
      #expect(outcome == .forbiddenCode)
      #expect(transport.writes.isEmpty, "a forbidden code was written")
    }
  }

  @Test("Factory reset and input switching are on the list")
  func forbiddenListCoversTheDangerousOnes() {
    #expect(WriteProbe.forbidden.contains(0x04), "restore factory defaults")
    #expect(WriteProbe.forbidden.contains(0x60), "input source")
    #expect(WriteProbe.forbidden.contains(0xD6), "power mode")
  }

  @Test("A register that keeps the written value is accepted")
  func detectsAcceptedWrite() {
    let transport = ScriptedTransport(
      readings: [0x8F: DDCReading(current: 20, maximum: 100)], honoursWrites: true
    )
    let outcome = WriteProbe.probe(VCPCode(rawValue: 0x8F), transport: transport)
    #expect(outcome.isAccepted)
  }

  /// The behaviour actually observed on the panel: writes are swallowed and the
  /// old value keeps coming back.
  @Test("A register that ignores writes is rejected")
  func detectsIgnoredWrite() {
    let transport = ScriptedTransport(
      readings: [0x62: DDCReading(current: 100, maximum: 100)], honoursWrites: false
    )
    let outcome = WriteProbe.probe(VCPCode(rawValue: 0x62), transport: transport)
    #expect(!outcome.isAccepted)
  }

  @Test("The probe value differs from what is already there")
  func probeValueIsDistinguishable() {
    let transport = ScriptedTransport(
      readings: [0x8F: DDCReading(current: 75, maximum: 100)], honoursWrites: true
    )
    _ = WriteProbe.probe(VCPCode(rawValue: 0x8F), transport: transport)
    // Otherwise a register that merely echoes its old value would look accepted.
    #expect(transport.writes.first?.value != 75)
  }

  @Test("The original value is restored after a successful probe")
  func restoresAfterSuccess() {
    let transport = ScriptedTransport(
      readings: [0x8F: DDCReading(current: 42, maximum: 100)], honoursWrites: true
    )
    _ = WriteProbe.probe(VCPCode(rawValue: 0x8F), transport: transport)
    #expect(transport.writes.last?.value == 42)
  }

  /// Restoration is in a defer, so it has to happen on the failing path too —
  /// that is the path where leaving the display altered would go unnoticed.
  @Test("The original value is restored after a rejected probe")
  func restoresAfterRejection() {
    let transport = ScriptedTransport(
      readings: [0x62: DDCReading(current: 88, maximum: 100)], honoursWrites: false
    )
    _ = WriteProbe.probe(VCPCode(rawValue: 0x62), transport: transport)
    #expect(transport.writes.last?.value == 88)
  }
}

/// A transport that answers only for the codes it was given, so a scan can be
/// exercised against a known display without hardware.
private final class ScriptedTransport: DDCTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UInt8: DDCReading]
  private let honoursWrites: Bool
  private var _writes: [(vcp: VCPCode, value: UInt16)] = []

  init(readings: [UInt8: DDCReading], honoursWrites: Bool = false) {
    self.values = readings
    self.honoursWrites = honoursWrites
  }

  var writes: [(vcp: VCPCode, value: UInt16)] {
    lock.withLock { _writes }
  }

  func read(_ vcp: VCPCode, timing: DDCTiming) throws -> DDCReading {
    try lock.withLock {
      guard let reading = values[vcp.rawValue] else {
        throw DDCError.unsupportedFeature(vcp)
      }
      return reading
    }
  }

  func write(_ vcp: VCPCode, value: UInt16, timing: DDCTiming) throws {
    lock.withLock {
      _writes.append((vcp, value))
      if honoursWrites, let existing = values[vcp.rawValue] {
        values[vcp.rawValue] = DDCReading(current: value, maximum: existing.maximum)
      }
    }
  }
}
