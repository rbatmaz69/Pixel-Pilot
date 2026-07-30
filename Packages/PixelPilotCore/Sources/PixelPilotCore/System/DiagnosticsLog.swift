import Foundation
import os

/// A bounded, in-memory record of what the DDC layer has been doing.
///
/// This exists because DDC failures are almost never reproducible on demand:
/// they depend on cable, port, panel firmware and timing. When something does go
/// wrong the user needs to be able to open a window and see the actual traffic,
/// not a spinner that stopped.
///
/// Deliberately a fixed-size ring: an always-on log must not grow without bound
/// in a process designed to sit idle for days.
public final class DiagnosticsLog: @unchecked Sendable {
  public enum Entry: Sendable {
    case ddcRead(vcp: VCPCode, reading: DDCReading)
    case ddcWrite(vcp: VCPCode, value: UInt16)
    case info(String)
    case warning(String)
    case failure(String)

    public var message: String {
      switch self {
      case let .ddcRead(vcp, reading):
        "read \(vcp) → \(reading.current)/\(reading.maximum)"
      case let .ddcWrite(vcp, value):
        "write \(vcp) ← \(value)"
      case let .info(text): text
      case let .warning(text): "⚠︎ \(text)"
      case let .failure(text): "✗ \(text)"
      }
    }
  }

  public struct Record: Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let entry: Entry
  }

  private let capacity: Int
  private let lock = NSLock()
  private var storage: [Record] = []
  private var nextID: UInt64 = 0

  private let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "ddc")

  public init(capacity: Int = 500) {
    self.capacity = capacity
    self.storage.reserveCapacity(capacity)
  }

  public func record(_ entry: Entry) {
    lock.lock()
    let record = Record(id: nextID, timestamp: Date(), entry: entry)
    nextID += 1
    storage.append(record)
    if storage.count > capacity {
      storage.removeFirst(storage.count - capacity)
    }
    lock.unlock()

    switch entry {
    case .failure:
      logger.error("\(entry.message, privacy: .public)")
    case .warning:
      logger.warning("\(entry.message, privacy: .public)")
    default:
      logger.debug("\(entry.message, privacy: .public)")
    }
  }

  /// Newest last.
  public func snapshot() -> [Record] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  public func clear() {
    lock.lock()
    storage.removeAll(keepingCapacity: true)
    lock.unlock()
  }
}
