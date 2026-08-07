import Foundation

/// A release number, ordered by what it means rather than by how it reads.
///
/// The whole point is that `0.10.0` is newer than `0.2.0`, which string
/// comparison gets backwards. Everything else here is in service of that one
/// fact.
///
/// Two spellings of the same number reach this type from two directions:
/// `MARKETING_VERSION` in `project.yml` is `0.2.0` and the git tag
/// `Scripts/release.sh` cuts from it is `v0.2.0`. Both parse, because the
/// alternative is a comparison that silently fails on the `v`.
///
/// Parsing is strict about everything else. Exactly three numeric components,
/// nothing after them: `0.3.0-beta1` does not parse, and that is deliberate
/// rather than an omission. `Scripts/release.sh` refuses any version that is
/// not `1.2.3`, so a tag with a suffix on it was made by hand and outside the
/// release path — and an app that guessed at what such a tag meant, and then
/// offered to install it, would be guessing about which build lands in
/// `/Applications`. `UpdateVerdict.unreadable` is what happens instead, and it
/// says so out loud rather than reporting "up to date".
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Reads `1.2.3`, or `v1.2.3`, and nothing else.
  public init?(_ string: String) {
    var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.first == "v" || text.first == "V" { text.removeFirst() }

    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }

    // `Int.init?` alone would accept "+1" and "-1", which are not components of
    // a version, and would accept the empty string as nil only by accident.
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
            let number = Int(part)
      else { return nil }
      numbers.append(number)
    }

    self.init(numbers[0], numbers[1], numbers[2])
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
