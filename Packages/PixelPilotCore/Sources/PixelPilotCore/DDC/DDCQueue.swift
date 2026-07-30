import Foundation

/// Serialises DDC traffic for one display and collapses bursts of writes.
///
/// Two problems this solves, both of which are the difference between a smooth
/// slider and a monitor that stutters or stops responding:
///
/// **Serialisation.** I2C is a shared bus with settling delays in the tens of
/// milliseconds. Two overlapping transactions do not queue, they corrupt each
/// other. `Arm64DDCTransport` is deliberately not thread-safe; this is the type
/// that makes it safe to use.
///
/// **Coalescing.** Dragging a slider produces hundreds of value changes per
/// second. A monitor can absorb roughly 20–30 DDC writes per second before it
/// starts dropping them or visibly lagging. Every intermediate value is
/// discarded — only the newest matters — and a trailing write guarantees the
/// value the user released on is the one that lands.
///
/// The blocking `usleep` calls inside the transport run on a dedicated
/// `DispatchQueue`, never on the Swift concurrency thread pool. Blocking a
/// cooperative thread for 50 ms per read would starve unrelated work.
public actor DDCQueue {
  private let transport: any DDCTransport
  private let ioQueue: DispatchQueue
  private let log: DiagnosticsLog?

  /// Minimum spacing between writes of the same feature while a burst is in
  /// flight. 40 ms caps sustained traffic at 25 writes/second.
  private let minimumWriteInterval: Duration

  public var timing: DDCTiming

  /// Newest requested value per feature. A pending value is overwritten rather
  /// than queued — that is the coalescing.
  private var pendingWrites: [VCPCode: UInt16] = [:]
  private var drainTask: Task<Void, Never>?
  private var lastWriteInstant: ContinuousClock.Instant?

  /// Last value we successfully wrote or read, per feature. Lets callers render
  /// current state without a DDC round trip — the app reads the panel once at
  /// connect and works from memory afterwards.
  private var cachedValues: [VCPCode: UInt16] = [:]

  public init(
    transport: any DDCTransport,
    timing: DDCTiming = .default,
    minimumWriteInterval: Duration = .milliseconds(40),
    log: DiagnosticsLog? = nil
  ) {
    self.transport = transport
    self.timing = timing
    self.minimumWriteInterval = minimumWriteInterval
    self.log = log
    self.ioQueue = DispatchQueue(
      label: "dev.rb.pixelpilot.ddc.\(UInt(bitPattern: ObjectIdentifier(transport).hashValue))",
      qos: .utility
    )
  }

  deinit {
    drainTask?.cancel()
  }

  // MARK: - Public surface

  public func cachedValue(for vcp: VCPCode) -> UInt16? { cachedValues[vcp] }

  public func setTiming(_ newTiming: DDCTiming) { timing = newTiming }

  /// Requests a new value. Returns immediately; the write happens on the I/O
  /// queue, throttled and coalesced.
  ///
  /// Fire-and-forget on purpose: a slider must not await the bus. Use
  /// `flush()` when you need to know the value landed.
  public func set(_ vcp: VCPCode, value: UInt16) {
    pendingWrites[vcp] = value
    startDrainingIfNeeded()
  }

  /// Waits until every pending write has been attempted.
  public func flush() async {
    while drainTask != nil {
      await drainTask?.value
    }
  }

  /// Writes a value and confirms it by reading back.
  ///
  /// Reserved for the end of an interaction and for diagnostics — it costs a
  /// full round trip on top of the write, so it has no place in a drag.
  @discardableResult
  public func setVerified(_ vcp: VCPCode, value: UInt16) async throws -> DDCReading {
    pendingWrites[vcp] = nil
    await flush()

    try await perform { [transport, timing] in
      try transport.write(vcp, value: value, timing: timing)
    }
    lastWriteInstant = .now

    let reading = try await perform { [transport, timing] in
      try transport.read(vcp, timing: timing)
    }
    cachedValues[vcp] = reading.current

    guard reading.current == value else {
      throw DDCError.verificationFailed(vcp, wrote: value, readBack: reading.current)
    }
    return reading
  }

  /// Reads a feature from the panel.
  ///
  /// Never call this on a schedule. Displays are polled exactly once, when they
  /// connect; after that the process holds state in memory. Periodic reads are
  /// the single easiest way to turn an idle menu bar app into a battery drain.
  public func read(_ vcp: VCPCode) async throws -> DDCReading {
    await flush()
    let reading = try await perform { [transport, timing] in
      try transport.read(vcp, timing: timing)
    }
    cachedValues[vcp] = reading.current
    return reading
  }

  /// One-shot capability probe. Same warning as `read`, six times over.
  public func probeCapabilities(features: [VCPCode] = VCPCode.probeSet) async -> DisplayCapabilities {
    await flush()
    let capabilities = await performIgnoringErrors { [transport, timing, log] in
      DisplayCapabilities.probe(transport: transport, timing: timing, features: features, log: log)
    }
    for (vcp, support) in capabilities?.features ?? [:] {
      if case let .supported(current, _) = support { cachedValues[vcp] = current }
    }
    return capabilities ?? DisplayCapabilities()
  }

  // MARK: - Draining

  /// Starts the drain loop if it is not already running.
  ///
  /// There is deliberately no repeating timer here. The loop exists only while
  /// there is work, and the actor is completely quiescent otherwise — no
  /// wakeups, no scheduled blocks.
  private func startDrainingIfNeeded() {
    guard drainTask == nil else { return }
    drainTask = Task { [weak self] in
      await self?.drain()
    }
  }

  private func drain() async {
    defer { drainTask = nil }

    while !pendingWrites.isEmpty {
      if let last = lastWriteInstant {
        let elapsed = ContinuousClock.now - last
        if elapsed < minimumWriteInterval {
          try? await Task.sleep(for: minimumWriteInterval - elapsed)
          if Task.isCancelled { return }
        }
      }

      // Re-read after the sleep: newer values may have arrived, and those are
      // the ones we want. Anything they replaced is dropped, never sent.
      guard let (vcp, value) = pendingWrites.popFirst() else { break }

      lastWriteInstant = .now
      do {
        try await perform { [transport, timing] in
          try transport.write(vcp, value: value, timing: timing)
        }
        cachedValues[vcp] = value
      } catch {
        log?.record(.failure("write \(vcp) = \(value): \(error)"))
      }
    }
  }

  // MARK: - Bridging to the I/O queue

  private func perform<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      ioQueue.async {
        continuation.resume(with: Result { try work() })
      }
    }
  }

  private func performIgnoringErrors<T: Sendable>(
    _ work: @escaping @Sendable () -> T
  ) async -> T? {
    await withCheckedContinuation { continuation in
      ioQueue.async {
        continuation.resume(returning: work())
      }
    }
  }
}
