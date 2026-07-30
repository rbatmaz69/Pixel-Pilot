import CDDCPrivate
import Foundation
import IOKit

/// DDC/CI over the Apple Silicon DCP display stack.
///
/// Thread safety: this type is *not* internally synchronised. I2C is a shared
/// bus with settling delays measured in tens of milliseconds; concurrent
/// transactions corrupt each other. All access must go through `DDCQueue`,
/// which serialises per display. The `@unchecked Sendable` conformance records
/// that contract rather than claiming the type is free-threaded.
public final class Arm64DDCTransport: DDCTransport, @unchecked Sendable {
  private let service: UnsafeMutableRawPointer
  private let log: DiagnosticsLog?

  /// True when the undocumented IOAVService entry points resolved on this system.
  public static var isSupported: Bool { PPAVServiceAvailable() }

  /// Wraps a `DCPAVServiceProxy` IORegistry entry. Returns nil when the service
  /// cannot be opened — which is the normal outcome for internal panels.
  public init?(ioService: io_service_t, log: DiagnosticsLog? = nil) {
    guard let handle = PPAVServiceCreate(ioService) else { return nil }
    self.service = handle
    self.log = log
  }

  deinit {
    PPAVServiceRelease(service)
  }

  // MARK: - DDCTransport

  public func write(_ vcp: VCPCode, value: UInt16, timing: DDCTiming = .default) throws {
    var packet = DDCPacket.setRequest(vcp, value: value)
    try send(&packet, vcp: vcp, timing: timing, operation: "set")
    log?.record(.ddcWrite(vcp: vcp, value: value))
  }

  public func read(_ vcp: VCPCode, timing: DDCTiming = .default) throws -> DDCReading {
    var lastError: Error = DDCError.malformedReply(bytes: [], detail: "no attempt made")

    for attempt in 0 ... timing.readRetries {
      if attempt > 0 {
        usleep(timing.retryWaitMicroseconds)
      }
      do {
        let parsed = try readOnce(vcp, timing: timing)
        // A bad checksum earns a retry, but on the final attempt we take the
        // values anyway: several panels answer correctly and checksum wrongly,
        // and refusing them would mean no DDC at all on that hardware.
        if parsed.checksumValid || attempt == timing.readRetries {
          if !parsed.checksumValid {
            log?.record(.warning("Accepting \(vcp) reply with bad checksum after \(attempt + 1) attempts"))
          }
          log?.record(.ddcRead(vcp: vcp, reading: parsed.reading))
          return parsed.reading
        }
        lastError = DDCError.malformedReply(bytes: [], detail: "checksum mismatch")
      } catch let error as DDCError {
        // The display telling us it has no such feature is a final answer;
        // retrying just wastes 50 ms per round.
        if case .unsupportedFeature = error { throw error }
        lastError = error
      }
    }

    log?.record(.failure("read \(vcp): \(lastError)"))
    throw lastError
  }

  // MARK: - Experimental

  /// Attempts `IOAVServiceCopyEDID`. The symbol is exported but undocumented and
  /// its signature is a guess, so this is reachable only from `ppctl probe-edid`
  /// — never from the app, where a wrong guess would be a crash rather than a
  /// failed command. Display identification uses `DisplayRegistry` instead.
  public func experimentalCopyEDID() -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let written = buffer.withUnsafeMutableBufferPointer { pointer in
      PPAVServiceCopyEDIDExperimental(service, pointer.baseAddress!, UInt32(pointer.count))
    }
    guard written > 0 else { return nil }
    return Array(buffer.prefix(Int(written)))
  }

  // MARK: - Transactions

  private func readOnce(_ vcp: VCPCode, timing: DDCTiming) throws -> DDCPacket.ParsedReply {
    var request = DDCPacket.getRequest(vcp)
    try send(&request, vcp: vcp, timing: timing, operation: "get request")

    usleep(timing.readWaitMicroseconds)

    var reply = [UInt8](repeating: 0, count: 12)
    let result = reply.withUnsafeMutableBytes { buffer in
      PPAVServiceReadI2C(
        service,
        DDCPacket.chipAddress,
        UInt32(vcp.dataAddress),
        buffer.baseAddress!,
        UInt32(buffer.count)
      )
    }
    guard result == kIOReturnSuccess else {
      throw DDCError.ioError(code: result, operation: "read")
    }
    return try DDCPacket.parseReply(reply, expecting: vcp)
  }

  /// Pushes a host → display packet, repeated `writeCycles` times because some
  /// panels reliably ignore the first one.
  ///
  /// The explicit `packet.count` matters: the reference implementation derives
  /// the length by scanning for the last non-zero byte, which silently truncates
  /// the packet whenever the trailing checksum happens to compute to zero.
  private func send(
    _ packet: inout [UInt8],
    vcp: VCPCode,
    timing: DDCTiming,
    operation: String
  ) throws {
    for _ in 0 ..< timing.writeCycles {
      usleep(timing.writeWaitMicroseconds)
      let result = packet.withUnsafeBytes { buffer in
        PPAVServiceWriteI2C(
          service,
          DDCPacket.chipAddress,
          UInt32(vcp.dataAddress),
          buffer.baseAddress!,
          UInt32(buffer.count)
        )
      }
      guard result == kIOReturnSuccess else {
        throw DDCError.ioError(code: result, operation: operation)
      }
    }
  }
}
