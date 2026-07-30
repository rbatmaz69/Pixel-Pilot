import Foundation

/// Reads every VCP code to find out what a display really implements.
///
/// Displays under-declare. The capability string is a self-report, and this one
/// lists 24 features while its scaler chip is a general-purpose part that
/// usually supports more. The scan exists to answer a question the display's own
/// answer cannot: is there an undocumented register behind the missing feature?
///
/// The classification is the substance here. A plain "responds / does not
/// respond" scan would be useless, because a dead register answers too: reading
/// audio volume on the panel this was developed against returns a perfectly
/// well-formed DDC reply carrying a maximum of 0xFFFF. Telling that apart from a
/// real control is the entire job.
public enum VCPScanner {
  public enum Classification: Sendable, Equatable {
    /// No reply, or the display explicitly declined the feature.
    case absent(reason: String)
    /// A well-formed reply that cannot describe a real control.
    case phantom(current: UInt16, maximum: UInt16, reason: String)
    /// A well-formed reply with a plausible range.
    case live(current: UInt16, maximum: UInt16)

    public var isLive: Bool {
      if case .live = self { return true }
      return false
    }
  }

  public struct Result: Sendable, Identifiable {
    public let code: UInt8
    /// The I2C data address the reply came from. Vendors occasionally park
    /// extra controls on the alternate one.
    public let dataAddress: UInt8
    public let classification: Classification
    /// Whether the display's own capability string mentions this code.
    /// An undeclared live register is the interesting case.
    public let isDeclared: Bool

    public var id: String { String(format: "%02X@%02X", code, dataAddress) }
    public var name: String { VCPCode(rawValue: code).description }
  }

  /// Verdicts a reading can produce, kept separate from the I/O so it can be
  /// tested without hardware.
  public static func classify(_ reading: DDCReading) -> Classification {
    // The tell. A control with no upper bound is not a control; 0xFFFF is what
    // an unimplemented register returns when the firmware answers anyway.
    if reading.maximum == 0xFFFF {
      return .phantom(
        current: reading.current, maximum: reading.maximum,
        reason: "maximum is 0xFFFF — register answers but is not implemented"
      )
    }
    if reading.maximum == 0 {
      return .phantom(
        current: reading.current, maximum: reading.maximum,
        reason: "maximum is 0 — no usable range"
      )
    }
    // A current value above the stated maximum means the two fields do not
    // describe the same thing.
    if reading.current > reading.maximum {
      return .phantom(
        current: reading.current, maximum: reading.maximum,
        reason: "current \(reading.current) exceeds maximum \(reading.maximum)"
      )
    }
    return .live(current: reading.current, maximum: reading.maximum)
  }

  public static func classify(_ error: any Error) -> Classification {
    if let ddcError = error as? DDCError {
      switch ddcError {
      case .unsupportedFeature:
        return .absent(reason: "display declined the feature")
      case let .ioError(_, operation):
        return .absent(reason: "I2C \(operation) failed")
      case .malformedReply:
        return .absent(reason: "no usable reply")
      default:
        break
      }
    }
    return .absent(reason: "\(error)")
  }

  /// Timing tuned for scanning rather than for control.
  ///
  /// One retry instead of four, because with the normal profile a code that does
  /// not exist costs five attempts and 256 of those take minutes. A register
  /// that needs five tries to answer is not one worth finding.
  ///
  /// `writeCycles` stays at 2. Dropping it to 1 looks like an obvious saving —
  /// the request is only 5 bytes — but this panel ignores the first request and
  /// answers the second. A scan with one cycle reported 255 of 256 registers
  /// absent, including brightness, which is known to work.
  public static let scanTiming = DDCTiming(
    writeWaitMicroseconds: 10_000,
    readWaitMicroseconds: 50_000,
    retryWaitMicroseconds: 20_000,
    writeCycles: 2,
    readRetries: 1
  )

  /// Scans every code on one data address.
  ///
  /// Read-only. A Get VCP Feature request cannot change display state, which is
  /// what makes sweeping undocumented registers acceptable — the same sweep with
  /// writes could hit a factory reset.
  public static func scan(
    transport: any DDCTransport,
    dataAddress: UInt8 = 0x51,
    declared: Set<UInt8> = [],
    timing: DDCTiming = scanTiming,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) -> [Result] {
    var results: [Result] = []
    results.reserveCapacity(256)

    for raw in UInt8.min ... UInt8.max {
      progress?(Int(raw) + 1, 256)

      let code = VCPCode(rawValue: raw)
      let classification: Classification
      do {
        classification = classify(try transport.read(code, at: dataAddress, timing: timing))
      } catch {
        classification = classify(error)
      }

      results.append(Result(
        code: raw,
        dataAddress: dataAddress,
        classification: classification,
        isDeclared: declared.contains(raw)
      ))
    }

    return results
  }

  /// Codes plausibly related to audio, for narrowing down what to write-test.
  ///
  /// The MCCS audio group, plus anything undeclared that answers with a range
  /// shaped like a volume.
  public static let audioCodes: Set<UInt8> = [
    0x62, // Audio: Speaker Volume
    0x63, // Audio: Speaker Select
    0x64, // Audio: Microphone Volume
    0x66, // Audio: Jack Connection Status
    0x8D, // Audio: Mute
    0x8F, // Audio: Treble
    0x91, // Audio: Bass
    0x93, // Audio: Balance
    0x94, // Audio: Processor Mode
  ]

  /// Live registers worth a write test, most promising first.
  ///
  /// A register with a standard meaning is never a candidate, even when its
  /// range looks like a volume. An earlier version skipped that check and
  /// proposed Clock, Clock Phase and the horizontal and vertical position
  /// controls — all 0–100 ranges, all vestigial analog controls that a digital
  /// panel carries in firmware and drives nothing with. Following those wastes
  /// write tests on registers whose meaning is already documented.
  ///
  /// So: the MCCS audio group, plus genuinely unknown codes shaped like a level.
  public static func audioCandidates(in results: [Result]) -> [Result] {
    results
      .filter(\.classification.isLive)
      .filter { result in
        if audioCodes.contains(result.code) { return true }
        guard VCPCode(rawValue: result.code).standardName == nil,
              !result.isDeclared,
              case let .live(_, maximum) = result.classification
        else { return false }
        return maximum == 100 || maximum == 64 || maximum == 10
      }
      .sorted { lhs, rhs in
        let lhsAudio = audioCodes.contains(lhs.code)
        let rhsAudio = audioCodes.contains(rhs.code)
        if lhsAudio != rhsAudio { return lhsAudio }
        return lhs.code < rhs.code
      }
  }
}
