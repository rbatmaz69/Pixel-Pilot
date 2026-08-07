import Foundation

/// One file attached to a release.
public struct ReleaseAsset: Sendable, Hashable, Decodable {
  public let name: String
  public let size: Int
  public let downloadURL: URL

  /// The checksum GitHub computed, as `sha256:<64 hex>`.
  ///
  /// Optional because it is a recent addition to the API and older releases
  /// predate it. `UpdatePolicy.sha256(fromDigest:)` is what turns it into
  /// something comparable; the raw string is kept so a future algorithm prefix
  /// is visible rather than silently misread as SHA-256.
  public let digest: String?

  public init(name: String, size: Int, downloadURL: URL, digest: String?) {
    self.name = name
    self.size = size
    self.downloadURL = downloadURL
    self.digest = digest
  }

  private enum CodingKeys: String, CodingKey {
    case name, size, digest
    case downloadURL = "browser_download_url"
  }
}

/// A published release, as much of it as this app has a use for.
public struct GitHubRelease: Sendable, Hashable, Decodable {
  public let tag: String
  public let name: String?
  /// The release notes, in GitHub-flavoured markdown.
  public let body: String?
  public let pageURL: URL
  public let publishedAt: Date?
  public let isPrerelease: Bool
  public let isDraft: Bool
  public let assets: [ReleaseAsset]

  public init(
    tag: String, name: String?, body: String?, pageURL: URL, publishedAt: Date?,
    isPrerelease: Bool, isDraft: Bool, assets: [ReleaseAsset]
  ) {
    self.tag = tag
    self.name = name
    self.body = body
    self.pageURL = pageURL
    self.publishedAt = publishedAt
    self.isPrerelease = isPrerelease
    self.isDraft = isDraft
    self.assets = assets
  }

  private enum CodingKeys: String, CodingKey {
    case name, body, assets
    case tag = "tag_name"
    case pageURL = "html_url"
    case publishedAt = "published_at"
    case isPrerelease = "prerelease"
    case isDraft = "draft"
  }
}

public enum ReleaseFeedError: Error, LocalizedError, Sendable, Equatable {
  /// GitHub is refusing for now. Unauthenticated callers get 60 requests an
  /// hour per address, which the once-a-day rule is nowhere near — but a shared
  /// address behind one NAT can be.
  case rateLimited(until: Date?)
  case http(status: Int)
  case notJSON

  public var errorDescription: String? {
    switch self {
    case let .rateLimited(until):
      if let until {
        let time = until.formatted(date: .omitted, time: .shortened)
        return "GitHub is rate-limiting this address. It will answer again after \(time)."
      }
      return "GitHub is rate-limiting this address. Try again later."
    case let .http(status):
      return "GitHub answered \(status)."
    case .notJSON:
      return "GitHub's answer was not in the shape this app expects."
    }
  }
}

/// Asks GitHub what the newest release is.
///
/// The one place in this application that touches the network, and it does the
/// smallest thing that answers the question: a single unauthenticated GET,
/// nothing sent, nothing stored on the far side. There is no telemetry hiding
/// in here and the Updates card says so.
///
/// The endpoint is injectable so the decoding can be tested against a captured
/// answer rather than against whatever GitHub is serving on the day the test
/// runs.
public struct ReleaseFeed: Sendable {
  public static let pixelPilot = URL(
    string: "https://api.github.com/repos/rbatmaz69/Pixel-Pilot/releases/latest"
  )!

  private let endpoint: URL
  private let session: URLSession
  private let userAgent: String

  public init(
    endpoint: URL = ReleaseFeed.pixelPilot,
    session: URLSession = .shared,
    userAgent: String = "PixelPilot"
  ) {
    self.endpoint = endpoint
    self.session = session
    self.userAgent = userAgent
  }

  public func latest() async throws -> GitHubRelease {
    var request = URLRequest(url: endpoint)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    // GitHub rejects API requests without one.
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    // A cached answer would make "Check now" a button that does nothing.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15

    let (data, response) = try await session.data(for: request)

    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      // 403 with nothing left on the clock is the rate limiter; 403 for any
      // other reason is not, and the two deserve different sentences.
      let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
      if (http.statusCode == 403 || http.statusCode == 429), remaining == "0" {
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
          .flatMap(Double.init)
          .map(Date.init(timeIntervalSince1970:))
        throw ReleaseFeedError.rateLimited(until: reset)
      }
      throw ReleaseFeedError.http(status: http.statusCode)
    }

    return try Self.decode(data)
  }

  /// Shared with the tests, so what they check is the decoding the app uses.
  public static func decode(_ data: Data) throws -> GitHubRelease {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(GitHubRelease.self, from: data)
    } catch is DecodingError {
      throw ReleaseFeedError.notJSON
    }
  }
}
