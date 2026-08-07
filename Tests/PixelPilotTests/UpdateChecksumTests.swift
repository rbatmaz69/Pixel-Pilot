import CryptoKit
import Foundation
import PixelPilotCore
import Testing

@testable import PixelPilot

/// The check that stands between a tampered download and `/Applications`.
///
/// There is no signing key for this app's releases — it is signed ad-hoc, which
/// anyone can reproduce — so the SHA-256 GitHub publishes beside the asset is
/// the only thing that makes a download verifiable at all. If this check is
/// wrong in the permissive direction, nothing else catches it.
@Suite("Update checksum")
@MainActor
struct UpdateChecksumTests {
  private func makeUpdater() -> Updater {
    let defaults = UserDefaults(suiteName: "checksum-\(UUID().uuidString)")!
    return Updater(preferences: Preferences(defaults: defaults), log: DiagnosticsLog())
  }

  private func write(_ data: Data) throws -> URL {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("checksum-\(UUID().uuidString).bin")
    try data.write(to: file)
    return file
  }

  private func asset(size: Int, digest: String?) -> ReleaseAsset {
    ReleaseAsset(
      name: "PixelPilot-9.9.9.dmg", size: size,
      downloadURL: URL(string: "https://example.invalid/x.dmg")!, digest: digest
    )
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @Test("Bytes matching the published digest pass")
  func acceptsMatching() throws {
    let data = Data("the real disk image".utf8)
    let file = try write(data)
    defer { try? FileManager.default.removeItem(at: file) }

    try makeUpdater().verifyChecksum(
      of: file, against: asset(size: data.count, digest: "sha256:\(sha256(data))")
    )
  }

  /// The case the whole mechanism exists for.
  @Test("Bytes that do not match are refused")
  func rejectsTampered() throws {
    let published = Data("the real disk image".utf8)
    let arrived = Data("something else entirely".utf8)
    let file = try write(arrived)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(throws: UpdateError.self) {
      // Same length, different content — so the size check cannot be what
      // catches this. Only the hash can.
      try makeUpdater().verifyChecksum(
        of: file,
        against: asset(size: arrived.count, digest: "sha256:\(sha256(published))")
      )
    }
  }

  @Test("A download that arrived short is refused before it is hashed")
  func rejectsTruncated() throws {
    let data = Data("half of it".utf8)
    let file = try write(data)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(throws: UpdateError.self) {
      try makeUpdater().verifyChecksum(
        of: file, against: asset(size: data.count * 2, digest: "sha256:\(sha256(data))")
      )
    }
  }

  /// Releases published before GitHub started sending a digest have none. The
  /// size check and the signature check are what is left, and the log says so —
  /// but the update is not blocked, because that would mean an app that can
  /// never update away from an old release.
  @Test("A release with no published digest is not blocked by this check")
  func toleratesMissingDigest() throws {
    let data = Data("an older release".utf8)
    let file = try write(data)
    defer { try? FileManager.default.removeItem(at: file) }

    try makeUpdater().verifyChecksum(of: file, against: asset(size: data.count, digest: nil))
  }

  /// A digest in an algorithm this app cannot compute reads as "no digest"
  /// rather than as a SHA-256 that will never match — which would make every
  /// download fail with a checksum error.
  @Test("A digest in another algorithm does not fail the download")
  func toleratesUnknownAlgorithm() throws {
    let data = Data("a future release".utf8)
    let file = try write(data)
    defer { try? FileManager.default.removeItem(at: file) }

    try makeUpdater().verifyChecksum(
      of: file, against: asset(size: data.count, digest: "sha512:\(String(repeating: "a", count: 128))")
    )
  }
}
