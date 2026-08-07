import Foundation

/// What the newest release means for the copy that is running.
public enum UpdateVerdict: Sendable, Equatable {
  /// Nothing newer is published.
  case upToDate
  case available(SemanticVersion)
  /// Newer, but this exact version was declined.
  case skipped(SemanticVersion)
  /// The newest release is tagged something this app cannot compare.
  ///
  /// Not folded into `upToDate`, because those are opposite claims: one says
  /// there is nothing to install, this one says the question could not be
  /// answered. See `SemanticVersion` for why a tag might not parse.
  case unreadable(tag: String)

  /// Whether anything should be shown. `skipped` is deliberately quiet.
  public var isActionable: Bool {
    if case .available = self { return true }
    return false
  }
}

/// The decisions behind checking for updates, with nothing to run them against.
///
/// Separated from the fetching and the installing for the usual reason in this
/// project: the arithmetic is where the mistakes are, and it can be tested in
/// microseconds without a network, a disk image or a second copy of the app.
public enum UpdatePolicy {
  /// How long a check is good for. A day is short enough that a fix is found
  /// within a day of looking, and long enough that the request is invisible
  /// against GitHub's 60-an-hour allowance.
  public static let checkInterval: TimeInterval = 24 * 60 * 60

  public static func verdict(
    latestTag: String,
    current: SemanticVersion,
    skipped: SemanticVersion? = nil
  ) -> UpdateVerdict {
    guard let latest = SemanticVersion(latestTag) else {
      return .unreadable(tag: latestTag)
    }
    guard latest > current else { return .upToDate }
    // Only this exact version is hidden. Declining 0.3.0 is a statement about
    // 0.3.0, and treating it as "stop telling me about updates" would turn one
    // click into a setting nobody chose and cannot find again.
    if let skipped, skipped == latest { return .skipped(latest) }
    return .available(latest)
  }

  /// Whether enough time has passed to ask again.
  ///
  /// The whole scheduling mechanism, and it is arithmetic on a stored date
  /// rather than a repeating timer — which is what lets an idle app stay at
  /// 0.0 % CPU while still noticing a release within a day of running.
  public static func shouldCheck(
    now: Date,
    lastCheck: Date?,
    interval: TimeInterval = checkInterval
  ) -> Bool {
    guard let lastCheck else { return true }
    // A clock that moved backwards — a correction, a timezone-confused restore
    // — would otherwise park the next check somewhere in the future and
    // suppress updates until it arrives. Ask now instead.
    if now < lastCheck { return true }
    return now.timeIntervalSince(lastCheck) >= interval
  }

  /// The disk image among a release's attachments.
  ///
  /// By extension rather than by name, so renaming the file in
  /// `Scripts/release.sh` does not quietly break updating for everyone already
  /// running the app.
  public static func diskImageAsset(in assets: [ReleaseAsset]) -> ReleaseAsset? {
    assets.first { $0.name.lowercased().hasSuffix(".dmg") }
  }

  /// The hexadecimal part of `sha256:<64 hex>`, lowercased, or nil.
  ///
  /// Nil for a digest in some other algorithm as well as for a malformed one.
  /// Both mean the same thing to the caller — there is no SHA-256 here to
  /// compare against — and quietly treating an unknown algorithm's digits as
  /// SHA-256 would fail every download with a checksum error.
  public static func sha256(fromDigest digest: String?) -> String? {
    guard let digest else { return nil }
    let parts = digest.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }

    let hex = parts[1].lowercased()
    guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
    return hex
  }
}
