import Foundation
import Testing

@testable import PixelPilotCore

/// Records what the queue actually put on the bus, so coalescing can be measured
/// rather than assumed.
final class RecordingTransport: DDCTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var _writes: [(vcp: VCPCode, value: UInt16)] = []
  private var _readCount = 0
  private var values: [VCPCode: UInt16] = [:]

  /// Simulated bus latency, so tests exercise the same interleaving as hardware.
  let latency: TimeInterval
  /// When set, reads return this instead of the stored value — used to force a
  /// verification mismatch.
  var readOverride: UInt16?

  init(latency: TimeInterval = 0.001, initial: [VCPCode: UInt16] = [:]) {
    self.latency = latency
    self.values = initial
  }

  var writes: [(vcp: VCPCode, value: UInt16)] {
    lock.withLock { _writes }
  }

  var readCount: Int {
    lock.withLock { _readCount }
  }

  func write(_ vcp: VCPCode, value: UInt16, timing: DDCTiming) throws {
    Thread.sleep(forTimeInterval: latency)
    lock.withLock {
      _writes.append((vcp, value))
      values[vcp] = value
    }
  }

  func read(_ vcp: VCPCode, timing: DDCTiming) throws -> DDCReading {
    Thread.sleep(forTimeInterval: latency)
    return lock.withLock {
      _readCount += 1
      return DDCReading(current: readOverride ?? values[vcp] ?? 0, maximum: 100)
    }
  }
}

@Suite("DDC queue")
struct DDCQueueTests {
  @Test("A burst of writes collapses, and the final value still lands")
  func coalescesBurst() async throws {
    let transport = RecordingTransport()
    let queue = DDCQueue(
      transport: transport, minimumWriteInterval: .milliseconds(40)
    )

    // What a slider drag looks like: many values, faster than any bus.
    for value in 1 ... 100 {
      await queue.set(.luminance, value: UInt16(value))
    }
    await queue.flush()

    let writes = transport.writes
    #expect(writes.count < 20, "expected coalescing, saw \(writes.count) writes")
    #expect(writes.last?.value == 100, "the value the user released on must be the one that lands")
    #expect(await queue.cachedValue(for: .luminance) == 100)
  }

  /// The throttle must not merge separate features into one another — brightness
  /// and contrast are independent controls.
  @Test("Different features are tracked separately")
  func keepsFeaturesDistinct() async throws {
    let transport = RecordingTransport()
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    await queue.set(.luminance, value: 40)
    await queue.set(.contrast, value: 70)
    await queue.flush()

    #expect(await queue.cachedValue(for: .luminance) == 40)
    #expect(await queue.cachedValue(for: .contrast) == 70)

    let written = Dictionary(transport.writes.map { ($0.vcp, $0.value) }, uniquingKeysWith: { _, last in last })
    #expect(written[.luminance] == 40)
    #expect(written[.contrast] == 70)
  }

  @Test("Sustained writes stay within the throttle budget")
  func respectsThrottle() async throws {
    let transport = RecordingTransport(latency: 0)
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(40))

    let start = ContinuousClock.now
    for value in 1 ... 30 {
      await queue.set(.luminance, value: UInt16(value))
      try await Task.sleep(for: .milliseconds(10))
    }
    await queue.flush()
    let elapsed = ContinuousClock.now - start

    // 300 ms of dragging at a 40 ms floor cannot produce more than ~9 writes,
    // plus the trailing one.
    let budget = Int(elapsed / .milliseconds(40)) + 2
    #expect(transport.writes.count <= budget,
            "saw \(transport.writes.count) writes in \(elapsed), budget \(budget)")
    #expect(transport.writes.last?.value == 30)
  }

  @Test("The queue is idle once the burst is done")
  func settlesToIdle() async throws {
    let transport = RecordingTransport()
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(10))

    await queue.set(.luminance, value: 55)
    await queue.flush()
    let afterFlush = transport.writes.count

    // Nothing may happen on its own afterwards — no repeating timer anywhere.
    try await Task.sleep(for: .milliseconds(150))
    #expect(transport.writes.count == afterFlush)
  }

  @Test("Verified writes confirm by reading back")
  func verifiedWriteSucceeds() async throws {
    let transport = RecordingTransport()
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    let reading = try await queue.setVerified(.luminance, value: 65)
    #expect(reading.current == 65)
    #expect(transport.readCount == 1)
  }

  @Test("A write that does not stick is reported")
  func verifiedWriteDetectsMismatch() async {
    let transport = RecordingTransport()
    transport.readOverride = 12
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    await #expect(throws: DDCError.self) {
      try await queue.setVerified(.luminance, value: 65)
    }
  }

  @Test("Reads populate the cache so the UI need not hit the bus again")
  func readPopulatesCache() async throws {
    let transport = RecordingTransport(initial: [.luminance: 33])
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    #expect(await queue.cachedValue(for: .luminance) == nil)
    let reading = try await queue.read(.luminance)
    #expect(reading.current == 33)
    #expect(await queue.cachedValue(for: .luminance) == 33)
  }

  @Test("Pending writes are flushed before a read, so the read is not stale")
  func flushesBeforeRead() async throws {
    let transport = RecordingTransport()
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    await queue.set(.luminance, value: 77)
    let reading = try await queue.read(.luminance)
    #expect(reading.current == 77)
  }

  @Test("Capability probing fills the cache from a single pass")
  func probeFillsCache() async {
    let transport = RecordingTransport(initial: [.luminance: 80, .contrast: 45])
    let queue = DDCQueue(transport: transport, minimumWriteInterval: .milliseconds(1))

    let capabilities = await queue.probeCapabilities(features: [.luminance, .contrast])
    #expect(capabilities.isUsable(.luminance))
    #expect(await queue.cachedValue(for: .luminance) == 80)
    #expect(await queue.cachedValue(for: .contrast) == 45)
  }
}
