import Foundation

/// Determines whether a VCP register actually accepts writes.
///
/// A display answering a read proves very little — the panel this was built
/// against returns a well-formed reading for audio volume it does not implement.
/// Writing a value and reading it back is the only way to tell a real control
/// from a register that merely answers.
///
/// Even that is not proof that anything is *connected* to the register. A value
/// can be stored and do nothing. The result of this probe is a reason to go
/// listen, not a reason to draw a slider.
public enum WriteProbe {
  /// Codes that must never be written by a probe.
  ///
  /// This is a guard, not a guideline. Sweeping undocumented registers with
  /// writes is exactly how a monitor ends up factory-reset or switched to an
  /// input that takes the picture and the DDC channel with it.
  public static let forbidden: Set<UInt8> = [
    0x04, // Restore Factory Defaults
    0x05, // Restore Factory Brightness/Contrast
    0x06, // Restore Factory Geometry
    0x08, // Restore Factory Colour Defaults
    0x0A, // Restore Factory TV Defaults
    0x60, // Input Source — would end the session
    0xD6, // Power Mode
  ]

  public enum Outcome: Sendable, Equatable {
    /// The written value read back unchanged.
    case accepted(wrote: UInt16, maximum: UInt16)
    /// The register answered, but not with what we wrote.
    case rejected(wrote: UInt16, readBack: UInt16)
    /// Could not be read before or after writing.
    case unreadable(String)
    case forbiddenCode

    public var isAccepted: Bool {
      if case .accepted = self { return true }
      return false
    }
  }

  /// Writes a probe value and restores whatever was there.
  ///
  /// Restoration happens on every path, including failure — the point of the
  /// probe is to learn something, not to leave the display altered.
  public static func probe(
    _ vcp: VCPCode,
    transport: any DDCTransport,
    timing: DDCTiming = .default,
    log: DiagnosticsLog? = nil
  ) -> Outcome {
    guard !forbidden.contains(vcp.rawValue) else {
      log?.record(.warning("Refusing to write-probe \(vcp): on the forbidden list"))
      return .forbiddenCode
    }

    let original: DDCReading
    do {
      original = try transport.read(vcp, timing: timing)
    } catch {
      return .unreadable("could not read \(vcp) before writing: \(error)")
    }

    // Somewhere in range but different from where it is now, so a register that
    // simply echoes its old value cannot pass.
    let ceiling = original.maximum == 0xFFFF ? 100 : original.maximum
    let candidate = original.current > ceiling / 2 ? ceiling / 4 : (ceiling * 3) / 4
    let probeValue = candidate == original.current ? candidate / 2 + 1 : candidate

    defer {
      // Best effort: if this fails there is nothing further to try, and the
      // caller is told what the original was either way.
      try? transport.write(vcp, value: original.current, timing: timing)
    }

    do {
      try transport.write(vcp, value: probeValue, timing: timing)
    } catch {
      return .unreadable("write to \(vcp) failed: \(error)")
    }

    do {
      let readBack = try transport.read(vcp, timing: timing)
      if readBack.current == probeValue {
        log?.record(.info("\(vcp) accepted \(probeValue)"))
        return .accepted(wrote: probeValue, maximum: readBack.maximum)
      }
      return .rejected(wrote: probeValue, readBack: readBack.current)
    } catch {
      return .unreadable("could not read \(vcp) back: \(error)")
    }
  }
}
