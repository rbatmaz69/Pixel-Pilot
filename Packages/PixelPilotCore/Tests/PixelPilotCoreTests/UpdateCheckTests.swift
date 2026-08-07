import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Semantic version")
struct SemanticVersionTests {
  /// The reason this type exists at all. Compared as text, "0.10.0" sorts
  /// before "0.2.0" and the app would refuse to update for the rest of its life
  /// once the minor number reached double figures.
  @Test("Ten is newer than two")
  func ordersNumerically() {
    #expect(SemanticVersion(0, 2, 0) < SemanticVersion(0, 10, 0))
    #expect(SemanticVersion(1, 0, 0) > SemanticVersion(0, 99, 99))
    #expect(SemanticVersion(0, 2, 3) > SemanticVersion(0, 2, 2))
    #expect(SemanticVersion(0, 2, 0) == SemanticVersion(0, 2, 0))
  }

  /// `MARKETING_VERSION` is `0.2.0` and the tag cut from it is `v0.2.0`. Both
  /// spellings reach the comparison, so both have to parse to the same thing.
  @Test("The tag and the bundle version parse alike")
  func acceptsTagPrefix() {
    #expect(SemanticVersion("v0.2.0") == SemanticVersion(0, 2, 0))
    #expect(SemanticVersion("0.2.0") == SemanticVersion(0, 2, 0))
    #expect(SemanticVersion("V1.20.300") == SemanticVersion(1, 20, 300))
    #expect(SemanticVersion(" 0.2.0 ") == SemanticVersion(0, 2, 0))
  }

  @Test("Anything that is not three numbers is refused", arguments: [
    "", "v", "1", "1.2", "1.2.3.4", "1.2.x", "1..3", "1.2.", "beta",
    "1.2.-3", "1.2.+3", "０.２.０",
  ])
  func rejectsMalformed(_ text: String) {
    #expect(SemanticVersion(text) == nil, "'\(text)' must not parse")
  }

  @Test("It prints back the way it came in")
  func describes() {
    #expect(SemanticVersion("v0.2.0")?.description == "0.2.0")
  }
}

@Suite("Update policy")
struct UpdatePolicyTests {
  private let current = SemanticVersion(0, 2, 0)

  @Test("A newer tag is offered")
  func offersNewer() {
    #expect(UpdatePolicy.verdict(latestTag: "v0.3.0", current: current)
      == .available(SemanticVersion(0, 3, 0)))
  }

  @Test("The same version, and older ones, are not")
  func staysQuietOtherwise() {
    #expect(UpdatePolicy.verdict(latestTag: "v0.2.0", current: current) == .upToDate)
    #expect(UpdatePolicy.verdict(latestTag: "v0.1.9", current: current) == .upToDate)
  }

  /// Skipping is a statement about one version, not a way to turn updates off.
  /// If declining 0.3.0 also hid 0.4.0, one click would have become a setting
  /// nobody chose and could not find again.
  @Test("Skipping one version does not hide the next")
  func skipIsNotAnOffSwitch() {
    let skipped = SemanticVersion(0, 3, 0)

    #expect(UpdatePolicy.verdict(latestTag: "v0.3.0", current: current, skipped: skipped)
      == .skipped(skipped))
    #expect(UpdatePolicy.verdict(latestTag: "v0.4.0", current: current, skipped: skipped)
      == .available(SemanticVersion(0, 4, 0)))
  }

  /// "Up to date" and "I could not tell" are opposite claims, and only one of
  /// them is true when a tag was made by hand outside the release script.
  @Test("An uncomparable tag is not reported as up to date")
  func unreadableTagIsItsOwnAnswer() {
    #expect(UpdatePolicy.verdict(latestTag: "v0.3.0-beta1", current: current)
      == .unreadable(tag: "v0.3.0-beta1"))
    #expect(UpdatePolicy.verdict(latestTag: "nightly", current: current)
      == .unreadable(tag: "nightly"))
  }

  @Test("Only an available update is worth showing")
  func actionability() {
    #expect(UpdateVerdict.available(SemanticVersion(1, 0, 0)).isActionable)
    #expect(!UpdateVerdict.upToDate.isActionable)
    #expect(!UpdateVerdict.skipped(SemanticVersion(1, 0, 0)).isActionable)
    #expect(!UpdateVerdict.unreadable(tag: "x").isActionable)
  }

  // MARK: - When to ask

  @Test("Never asked before means ask now")
  func firstRunChecks() {
    #expect(UpdatePolicy.shouldCheck(now: .now, lastCheck: nil))
  }

  @Test("A day is the line")
  func waitsADay() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day = UpdatePolicy.checkInterval

    #expect(!UpdatePolicy.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-day + 1)))
    #expect(UpdatePolicy.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-day)))
    #expect(UpdatePolicy.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-day * 30)))
  }

  /// A clock that moved backwards would otherwise leave the last check sitting
  /// in the future, and updates suppressed until real time caught up with it.
  @Test("A clock that went backwards does not park the next check in the future")
  func survivesClockSkew() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(UpdatePolicy.shouldCheck(now: now, lastCheck: now.addingTimeInterval(60 * 60 * 24 * 365)))
  }

  // MARK: - Picking the file

  @Test("The disk image is found by extension, not by name")
  func picksDiskImage() {
    let assets = [
      asset("PixelPilot-0.3.0.dmg.sha256"),
      asset("SomethingElse.zip"),
      asset("PixelPilot-0.3.0.dmg"),
    ]
    #expect(UpdatePolicy.diskImageAsset(in: assets)?.name == "PixelPilot-0.3.0.dmg")
  }

  @Test("A release with nothing to install offers nothing")
  func noDiskImage() {
    #expect(UpdatePolicy.diskImageAsset(in: []) == nil)
    #expect(UpdatePolicy.diskImageAsset(in: [asset("notes.txt")]) == nil)
  }

  // MARK: - The checksum

  @Test("A SHA-256 digest becomes comparable hex")
  func readsDigest() {
    let hex = String(repeating: "a1", count: 32)
    #expect(UpdatePolicy.sha256(fromDigest: "sha256:\(hex)") == hex)
    #expect(UpdatePolicy.sha256(fromDigest: "SHA256:\(hex.uppercased())") == hex)
  }

  /// An unknown algorithm has to read as "no SHA-256 here" rather than as a
  /// SHA-256 that will not match, which would fail every download instead of
  /// falling back to the other checks.
  @Test("Anything that is not a SHA-256 digest reads as absent", arguments: [
    nil, "", "sha512:abc", "abc", "sha256:", "sha256:tooshort",
    "sha256:" + String(repeating: "z", count: 64),
  ] as [String?])
  func rejectsOtherDigests(_ digest: String?) {
    #expect(UpdatePolicy.sha256(fromDigest: digest) == nil)
  }

  private func asset(_ name: String) -> ReleaseAsset {
    ReleaseAsset(
      name: name, size: 1, downloadURL: URL(string: "https://example.invalid/\(name)")!,
      digest: nil
    )
  }
}

@Suite("Release feed")
struct ReleaseFeedTests {
  /// Decoded from an answer GitHub actually sent, captured with `curl` rather
  /// than written from memory of the documentation. Every other test here is
  /// about our own arithmetic; this one is the only check that we are reading
  /// the right keys out of somebody else's JSON.
  @Test("A real answer from the API decodes")
  func decodesCapturedResponse() throws {
    let url = try #require(
      Bundle.module.url(forResource: "latest-release", withExtension: "json"),
      "the captured API answer is missing from the test bundle"
    )
    let release = try ReleaseFeed.decode(try Data(contentsOf: url))

    #expect(release.tag == "v0.2.0")
    #expect(!release.isDraft)
    #expect(!release.isPrerelease)
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    #expect(release.publishedAt != nil)
    #expect(release.body?.isEmpty == false)

    let dmg = try #require(UpdatePolicy.diskImageAsset(in: release.assets))
    #expect(dmg.name == "PixelPilot-0.2.0.dmg")
    #expect(dmg.size > 0)
    #expect(dmg.downloadURL.scheme == "https")

    // The digest is what makes an unsigned download verifiable at all, so its
    // absence from a live answer is worth failing over rather than shrugging at.
    let hex = try #require(UpdatePolicy.sha256(fromDigest: dmg.digest))
    #expect(hex.count == 64)

    #expect(UpdatePolicy.verdict(latestTag: release.tag, current: SemanticVersion(0, 1, 0))
      == .available(SemanticVersion(0, 2, 0)))
  }

  @Test("Something that is not a release reads as a shape error")
  func rejectsNonsense() {
    #expect(throws: ReleaseFeedError.notJSON) {
      try ReleaseFeed.decode(Data(#"{"nope": true}"#.utf8))
    }
  }
}
