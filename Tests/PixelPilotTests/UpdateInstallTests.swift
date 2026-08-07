import Foundation
import Testing

@testable import PixelPilot

/// The script that replaces the running application, run for real.
///
/// This is the most destructive code in the app: it is handed the path of
/// `/Applications/Pixel Pilot.app` and told to overwrite it, from a shell with
/// no window to report into and no way to ask anything. Reading it is not
/// enough — these tests run the actual generated script against throwaway
/// directories, including the paths where it fails.
///
/// The waiting and the reopening are not exercised here. Those need a process
/// to outlive and a bundle to launch; what can go irreversibly wrong is the
/// swap, and that is what `RelaunchHandoff.swap` isolates.
@Suite("Replacing the app bundle")
struct RelaunchHandoffTests {
  /// Runs the swap exactly as the detached shell would.
  private func runSwap(bundle: URL, replacement: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", RelaunchHandoff.swap(bundle: bundle, with: replacement)]
    process.standardError = Pipe()
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// A directory standing in for an app bundle, with one identifiable file.
  private func makeBundle(at url: URL, marker: String) throws {
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true
    )
    try marker.write(
      to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8
    )
  }

  private func marker(in bundle: URL) -> String? {
    try? String(contentsOf: bundle.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
  }

  private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  @Test("The new bundle ends up where the old one was")
  func replaces() throws {
    try inTemporaryDirectory { root in
      let bundle = root.appendingPathComponent("Pixel Pilot.app")
      let replacement = root.appendingPathComponent("new/Pixel Pilot.app")
      try makeBundle(at: bundle, marker: "old")
      try makeBundle(at: replacement, marker: "new")

      _ = try runSwap(bundle: bundle, replacement: replacement)

      #expect(marker(in: bundle) == "new")
      // The backup is the safety net during the copy, not a leftover after it.
      #expect(!FileManager.default.fileExists(atPath: bundle.path + ".old"))
    }
  }

  /// The path that matters most. If the copy fails halfway there has to still
  /// be a working app on disk — the alternative is a user left with no
  /// application and a shell script that cannot tell them why.
  @Test("A failed copy puts the old bundle back")
  func restoresOnFailure() throws {
    try inTemporaryDirectory { root in
      let bundle = root.appendingPathComponent("Pixel Pilot.app")
      try makeBundle(at: bundle, marker: "old")
      // Nothing at this path, so `ditto` fails.
      let missing = root.appendingPathComponent("nothing-here.app")

      _ = try runSwap(bundle: bundle, replacement: missing)

      #expect(marker(in: bundle) == "old", "the original app must survive a failed update")
      #expect(!FileManager.default.fileExists(atPath: bundle.path + ".old"))
    }
  }

  /// A previous attempt that died between `mv` and `ditto` leaves a `.old`
  /// behind. The next run has to clear it rather than fail against it.
  @Test("A leftover backup from an earlier attempt does not block the next one")
  func clearsStaleBackup() throws {
    try inTemporaryDirectory { root in
      let bundle = root.appendingPathComponent("Pixel Pilot.app")
      let replacement = root.appendingPathComponent("new/Pixel Pilot.app")
      try makeBundle(at: bundle, marker: "old")
      try makeBundle(at: replacement, marker: "new")
      try makeBundle(at: URL(fileURLWithPath: bundle.path + ".old"), marker: "stale")

      _ = try runSwap(bundle: bundle, replacement: replacement)

      #expect(marker(in: bundle) == "new")
      #expect(!FileManager.default.fileExists(atPath: bundle.path + ".old"))
    }
  }

  /// The real destination has a space in it, and a user can rename an app to
  /// anything the filesystem accepts. Paths go into the script as single-quoted
  /// words for that reason, and this is the check that the quoting holds.
  @Test("Awkward characters in the path do not break the script", arguments: [
    "Pixel Pilot.app",
    "Pixel's Pilot.app",
    "Pixel $HOME `Pilot`.app",
    "Pixel \"Pilot\".app",
    "Pixel;rm -rf x.app",
  ])
  func survivesAwkwardNames(_ name: String) throws {
    try inTemporaryDirectory { root in
      let bundle = root.appendingPathComponent(name)
      let replacement = root.appendingPathComponent("new/\(name)")
      try makeBundle(at: bundle, marker: "old")
      try makeBundle(at: replacement, marker: "new")

      _ = try runSwap(bundle: bundle, replacement: replacement)

      #expect(marker(in: bundle) == "new", "'\(name)' was not handled as one shell word")
    }
  }
}

/// What the Updates card makes of a real set of release notes.
@Suite("Release notes on the card")
@MainActor
struct ReleaseNotesTests {
  /// The notes `Scripts/release.sh` writes open with a centred HTML block and
  /// the install instructions, which are addressed to somebody who does not
  /// have the app. The person reading this card has it open.
  @Test("The install boilerplate is dropped and the changelog kept")
  func trimsInstallBoilerplate() throws {
    let body = """
      <div align="center">

      <img src="https://example.invalid/icon.png" width="96" alt="Pixel Pilot">

      **Brightness, contrast and volume.**

      </div>

      ## 📦 Install

      1. Download it.
      2. Drag it to Applications.

      ## What's Changed
      * Find, mark and work on a bad pixel by @rbatmaz69 in https://example.invalid/pull/1

      **Full Changelog**: https://example.invalid/compare/v0.1.0...v0.2.0
      """

    let notes = try #require(UpdateSettings.readableNotes(body))
    let text = String(notes.characters)

    #expect(text.contains("Find, mark and work on a bad pixel"))
    #expect(!text.contains("Drag it to Applications"), "install steps are not news")
    #expect(!text.contains("<div"), "raw HTML must never reach the card")
  }

  @Test("Notes with no changelog section still show something")
  func keepsPlainNotes() throws {
    let notes = try #require(UpdateSettings.readableNotes("Fixed the thing that was **broken**."))
    #expect(String(notes.characters).contains("Fixed the thing"))
    // The markdown is parsed, so the asterisks are formatting rather than text.
    #expect(!String(notes.characters).contains("**"))
  }

  @Test("Nothing to say produces nothing to draw")
  func emptyIsNil() {
    #expect(UpdateSettings.readableNotes(nil) == nil)
    #expect(UpdateSettings.readableNotes("") == nil)
    #expect(UpdateSettings.readableNotes("<div align=\"center\"></div>") == nil)
  }
}
