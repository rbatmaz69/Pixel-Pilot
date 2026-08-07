import AppKit
import CryptoKit
import Foundation
import PixelPilotCore

/// Where the updater is, as one value.
///
/// A single enum rather than a handful of booleans, because the states really
/// are exclusive and the combinations that booleans permit — downloading and
/// failed, checking and ready — are all nonsense the view would have to rule
/// out by hand.
enum UpdatePhase: Equatable {
  case idle
  case checking
  /// Asked, and there is nothing newer. The date is when that was established,
  /// which is the only part worth showing.
  case upToDate(Date)
  case available(GitHubRelease)
  case downloading(GitHubRelease, fraction: Double)
  case verifying(GitHubRelease)
  /// Checked and mounted; `app` is inside a mounted image and is what will be
  /// copied into place.
  case readyToInstall(GitHubRelease, app: URL)
  case installing
  case failed(String)
}

/// Whether this copy of the app can replace itself.
enum InstallCapability: Equatable {
  case canInstall
  /// The bundle is somewhere this process cannot write — a read-only volume, a
  /// build directory owned by someone else, or a disk image.
  case notWritable
}

/// Finds out whether there is a newer release, and installs it.
///
/// The design constraint that shapes everything here: **the app is signed
/// ad-hoc**, and macOS ties the Accessibility grant to the code signature. A
/// new release is a new signature, so updating always costs the permission that
/// makes the brightness keys work. That is not something to bury — every path
/// through this class ends up telling the user, and
/// `GlobalSettings.pendingUpdateFromVersion` is what makes the *next* launch
/// say it too, at the moment it actually matters.
///
/// The second constraint: there is no signing key to verify a download with.
/// `codesign --verify` on an ad-hoc bundle proves it is intact, not that it is
/// ours, because anyone can produce an ad-hoc signature. What is actually
/// checked here is the SHA-256 that GitHub publishes alongside the asset,
/// fetched over the same TLS connection as the release itself. That is a real
/// guarantee against a corrupted or truncated download and against a tampered
/// CDN object; it is not a guarantee against GitHub itself, and the Updates
/// page says exactly that rather than implying more.
///
/// Nothing here runs on a timer. `check()` is called at launch and when the
/// Updates page appears, and `UpdatePolicy.shouldCheck` turns both into at most
/// one request a day by comparing a stored date against the clock.
@MainActor
@Observable
final class Updater {
  private(set) var phase: UpdatePhase = .idle

  /// The mounted image, kept so it can be detached again. Mounting is the one
  /// thing here with a footprint outside this process.
  @ObservationIgnored private var mountPoint: URL?
  @ObservationIgnored private var downloadedImage: URL?
  @ObservationIgnored private var work: Task<Void, Never>?

  private let preferences: Preferences
  private let feed: ReleaseFeed
  private let log: DiagnosticsLog

  /// Called the first time a particular version is found, and not again for
  /// that version. The notification lives on the other side of this so the
  /// updater has no opinion about `UserNotifications`.
  @ObservationIgnored var onUpdateFound: ((GitHubRelease, SemanticVersion) -> Void)?

  init(preferences: Preferences = .shared, feed: ReleaseFeed? = nil, log: DiagnosticsLog) {
    self.preferences = preferences
    self.log = log
    self.feed = feed ?? ReleaseFeed(
      userAgent: "PixelPilot/\(Self.currentVersionString) (macOS; +https://github.com/rbatmaz69/Pixel-Pilot)"
    )
  }

  // MARK: - This copy

  static var currentVersionString: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  static var currentBuildString: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  }

  var currentVersion: SemanticVersion {
    SemanticVersion(Self.currentVersionString) ?? SemanticVersion(0, 0, 0)
  }

  var lastCheck: Date? { preferences.global.lastUpdateCheck }

  var automaticChecks: Bool {
    get { preferences.global.automaticUpdateChecks }
    set { preferences.updateGlobal { $0.automaticUpdateChecks = newValue } }
  }

  /// A release is waiting, whatever stage of fetching it is at.
  var hasUpdate: Bool {
    switch phase {
    case .available, .downloading, .verifying, .readyToInstall: true
    default: false
    }
  }

  var isBusy: Bool {
    switch phase {
    case .checking, .downloading, .verifying, .installing: true
    default: false
    }
  }

  /// Whether replacing the running bundle is something this process can do.
  ///
  /// `/Applications` is `root:admin` and group-writable, and an app dragged
  /// there is owned by the user who dragged it, so the ordinary installation
  /// needs no privilege escalation and no helper tool. A copy run from a build
  /// directory, a disk image or another user's folder is a different matter,
  /// and gets told so instead of a button that fails.
  var installCapability: InstallCapability {
    let bundle = Bundle.main.bundleURL
    let parent = bundle.deletingLastPathComponent()
    let manager = FileManager.default
    return manager.isWritableFile(atPath: bundle.path)
      && manager.isWritableFile(atPath: parent.path) ? .canInstall : .notWritable
  }

  // MARK: - Checking

  /// Asks GitHub, unless it was asked recently.
  ///
  /// `force` is the "Check now" button and skips only the interval, never the
  /// switch: an automatic check that has been turned off stays off.
  func check(force: Bool = false) {
    guard !isBusy else { return }
    let settings = preferences.global
    if !force {
      guard settings.automaticUpdateChecks else { return }
      guard UpdatePolicy.shouldCheck(now: .now, lastCheck: settings.lastUpdateCheck) else { return }
    }

    phase = .checking
    work = Task { [weak self] in
      guard let self else { return }
      do {
        let release = try await feed.latest()
        guard !Task.isCancelled else { return }
        apply(release)
      } catch {
        guard !Task.isCancelled else { return }
        // The date is written on failure too. Without that, an app that cannot
        // reach GitHub — offline, or behind a captive portal — would retry on
        // every single launch, which is the closest thing to a polling loop
        // this app could accidentally grow.
        preferences.updateGlobal { $0.lastUpdateCheck = .now }
        log.record(.warning("update check failed: \(error.localizedDescription)"))
        phase = .failed(Self.sentence(for: error))
      }
    }
  }

  private func apply(_ release: GitHubRelease) {
    preferences.updateGlobal { $0.lastUpdateCheck = .now }

    // A draft is not published and a pre-release was not meant for everyone.
    // `releases/latest` already excludes both, so this is belt and braces for
    // the day that endpoint is swapped for `releases`.
    guard !release.isDraft, !release.isPrerelease else {
      phase = .upToDate(.now)
      return
    }

    let skipped = preferences.global.skippedUpdateVersion.flatMap(SemanticVersion.init)
    switch UpdatePolicy.verdict(latestTag: release.tag, current: currentVersion, skipped: skipped) {
    case .upToDate:
      log.record(.info("update check: \(release.tag) is not newer than \(currentVersion)"))
      phase = .upToDate(.now)

    case let .skipped(version):
      log.record(.info("update check: \(version) is available but was skipped"))
      phase = .upToDate(.now)

    case let .unreadable(tag):
      // Not `upToDate`: that would be a claim, and this is the absence of one.
      log.record(.warning("update check: '\(tag)' is not a version this app can compare"))
      phase = .failed("The newest release is tagged '\(tag)', which is not a version "
        + "this app knows how to compare. Have a look at the releases page.")

    case let .available(version):
      guard UpdatePolicy.diskImageAsset(in: release.assets) != nil else {
        log.record(.warning("update check: \(version) has no disk image attached"))
        phase = .failed("\(version) is out, but it has no disk image attached — "
          + "so there is nothing here to install. Have a look at the releases page.")
        return
      }
      log.record(.info("update check: \(version) is available"))
      phase = .available(release)
      onUpdateFound?(release, version)
    }
  }

  /// Never offer this version again.
  func skip(_ release: GitHubRelease) {
    guard let version = SemanticVersion(release.tag) else { return }
    preferences.updateGlobal { $0.skippedUpdateVersion = version.description }
    cleanUp()
    phase = .upToDate(.now)
  }

  /// Forget a skip, so the version comes back on the next check.
  func unskip() {
    preferences.updateGlobal { $0.skippedUpdateVersion = nil }
  }

  var skippedVersion: SemanticVersion? {
    preferences.global.skippedUpdateVersion.flatMap(SemanticVersion.init)
  }

  // MARK: - Downloading

  func download(_ release: GitHubRelease) {
    guard !isBusy, let asset = UpdatePolicy.diskImageAsset(in: release.assets) else { return }

    phase = .downloading(release, fraction: 0)
    work = Task { [weak self] in
      guard let self else { return }
      do {
        let image = try await fetch(asset, of: release)
        guard !Task.isCancelled else { return }

        phase = .verifying(release)
        try verifyChecksum(of: image, against: asset)
        let app = try mountAndFindApp(in: image)

        guard !Task.isCancelled else { return }
        downloadedImage = image
        log.record(.info("update \(release.tag): verified and mounted"))
        phase = .readyToInstall(release, app: app)
      } catch {
        guard !Task.isCancelled else { return }
        cleanUp()
        log.record(.failure("update \(release.tag): \(error.localizedDescription)"))
        phase = .failed(Self.sentence(for: error))
      }
    }
  }

  private func fetch(_ asset: ReleaseAsset, of release: GitHubRelease) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelPilotUpdate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(asset.name)

    let published = asset.size
    let driver = DownloadDriver { [weak self] written, expected in
      // The release metadata is the more trustworthy length: GitHub redirects
      // to a CDN, and a redirect chain can report -1 for the content length.
      let total = expected > 0 ? Double(expected) : Double(max(published, 1))
      Task { @MainActor in
        // Only while still downloading: a late callback must not drag the
        // phase back out of verifying.
        guard let self, case .downloading = self.phase else { return }
        self.phase = .downloading(release, fraction: min(Double(written) / total, 1))
      }
    }

    return try await driver.download(asset.downloadURL, to: file)
  }

  // MARK: - Checking what arrived

  /// Internal rather than private so `UpdateChecksumTests` can reach it. This
  /// is the one check standing between a tampered or truncated download and the
  /// bundle in `/Applications`, and it is worth testing against real bytes
  /// rather than trusting that it was read correctly.
  func verifyChecksum(of file: URL, against asset: ReleaseAsset) throws {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)

    guard data.count == asset.size else {
      throw UpdateError.wrongSize(expected: asset.size, got: data.count)
    }

    guard let expected = UpdatePolicy.sha256(fromDigest: asset.digest) else {
      // Older releases predate GitHub publishing a digest. The size check above
      // and the signature check below are what is left; saying so in the log
      // beats pretending the download was verified when it was not.
      log.record(.warning("update: no SHA-256 published for \(asset.name); "
        + "the download could only be size-checked"))
      return
    }

    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else {
      throw UpdateError.checksumMismatch(expected: expected, got: actual)
    }
  }

  /// Mounts the image and returns the app inside it, having checked that it is
  /// actually this app.
  private func mountAndFindApp(in image: URL) throws -> URL {
    let mount = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelPilotMount-\(UUID().uuidString)", isDirectory: true)

    // `-nobrowse` keeps it out of the Finder sidebar, `-readonly` because
    // nothing here writes to it, and `-noautoopen` so mounting does not throw a
    // window in the user's face mid-update.
    let attach = try Self.run("/usr/bin/hdiutil", [
      "attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
      "-mountpoint", mount.path,
    ])
    guard attach.status == 0 else {
      throw UpdateError.mountFailed(attach.errorText)
    }
    mountPoint = mount

    let contents = (try? FileManager.default.contentsOfDirectory(
      at: mount, includingPropertiesForKeys: nil
    )) ?? []
    guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
      throw UpdateError.noAppInImage
    }

    // What this proves and what it does not: the bundle is internally
    // consistent and claims our identifier. It does not prove authorship —
    // an ad-hoc signature is not attributable to anyone. It is here to catch a
    // disk image that is not the thing it was supposed to be, which is a
    // different failure from a corrupted one and would otherwise be found only
    // after the running app had been replaced with it.
    let signature = try Self.run("/usr/bin/codesign", ["-dvvv", app.path])
    guard signature.errorText.contains("Identifier=dev.rb.pixelpilot") else {
      throw UpdateError.wrongApp(app.lastPathComponent)
    }
    let verify = try Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
    guard verify.status == 0 else {
      throw UpdateError.signatureBroken(verify.errorText)
    }

    return app
  }

  // MARK: - Installing

  /// Replaces this bundle with the downloaded one and restarts.
  ///
  /// The point of no return, and the last thing that happens in this process.
  func install(_ release: GitHubRelease, from app: URL, quit: () -> Void) {
    guard installCapability == .canInstall else { return }
    phase = .installing

    // Written before the swap, not after: after, this process no longer exists.
    // The build that comes up next reads it and explains the missing
    // Accessibility grant, which is the whole reason it is recorded.
    preferences.updateGlobal {
      $0.pendingUpdateFromVersion = Self.currentVersionString
      $0.skippedUpdateVersion = nil
    }
    log.record(.info("update \(release.tag): installing over \(Bundle.main.bundleURL.path)"))

    // The mount has to survive until `ditto` has read from it, and `ditto` runs
    // after this process is gone — so this is the one path that deliberately
    // does not detach. The image is on a temporary volume that goes at reboot,
    // and the replacement app unmounts anything left over at launch.
    RelaunchHandoff.replaceAndRelaunch(bundle: Bundle.main.bundleURL, with: app)
    quit()
  }

  /// Detaches a stale mount left behind by an update that installed.
  ///
  /// Called at launch. The previous process could not do it: it had to leave
  /// the image mounted for `ditto` and then exit.
  static func detachStaleMounts() {
    let temporary = FileManager.default.temporaryDirectory
    let leftovers = (try? FileManager.default.contentsOfDirectory(
      at: temporary, includingPropertiesForKeys: nil
    )) ?? []
    for url in leftovers where url.lastPathComponent.hasPrefix("PixelPilotMount-") {
      _ = try? run("/usr/bin/hdiutil", ["detach", url.path, "-force"])
      try? FileManager.default.removeItem(at: url)
    }
    for url in leftovers where url.lastPathComponent.hasPrefix("PixelPilotUpdate-") {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - After an update

  /// The version this build replaced, if the last thing that happened here was
  /// an update. Reading it does not clear it; `acknowledgeUpdate()` does.
  var justUpdatedFrom: SemanticVersion? {
    preferences.global.pendingUpdateFromVersion.flatMap(SemanticVersion.init)
  }

  func acknowledgeUpdate() {
    preferences.updateGlobal { $0.pendingUpdateFromVersion = nil }
  }

  // MARK: - Tidying

  func cancel() {
    work?.cancel()
    work = nil
    cleanUp()
    phase = .idle
  }

  /// Unmounts and deletes anything this updater put on disk.
  private func cleanUp() {
    if let mountPoint {
      _ = try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
      self.mountPoint = nil
    }
    if let downloadedImage {
      try? FileManager.default.removeItem(at: downloadedImage.deletingLastPathComponent())
      self.downloadedImage = nil
    }
  }

  /// Reveals the disk image, for a copy of the app that cannot replace itself.
  func revealDownload() {
    guard let downloadedImage else { return }
    NSWorkspace.shared.activateFileViewerSelecting([downloadedImage])
  }

  // MARK: - Running tools

  private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, errorText: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments

    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()

    try process.run()
    // Read before waiting: a tool that fills the pipe buffer blocks forever
    // otherwise, and `codesign -dvvv` is chatty.
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
  }

  private static func sentence(for error: any Error) -> String {
    if let update = error as? UpdateError { return update.sentence }
    if let feed = error as? ReleaseFeedError { return feed.errorDescription ?? "\(feed)" }
    if (error as? URLError)?.code == .notConnectedToInternet {
      return "There is no network connection, so GitHub could not be asked."
    }
    if error is CancellationError { return "Stopped." }
    return error.localizedDescription
  }
}

/// Downloads a file, reporting how far it has got.
///
/// A **session-level** delegate driving a continuation, rather than the much
/// tidier `await session.download(from:delegate:)`. That form was written
/// first, and a live run against the real release showed the progress bar
/// sitting at zero for the entire download: the per-task delegate it takes
/// never receives `didWriteData`, on the shared session or on one of its own.
/// A session delegate does, so that is what this is.
///
/// Its callbacks arrive on `URLSession`'s own queue, which is why the progress
/// handler hops to the main actor and why the continuation is guarded by a
/// lock — cancellation can come from a different thread again.
private final class DownloadDriver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let onProgress: @Sendable (Int64, Int64) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, any Error>?
  private var task: URLSessionDownloadTask?
  private var destination: URL?

  init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.onProgress = onProgress
  }

  func download(_ url: URL, to file: URL) async throws -> URL {
    lock.withLock { destination = file }

    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    // Not `invalidateAndCancel`: the transfer is finished by the time this
    // returns, and cancelling would race the delegate callback that resumed it.
    defer { session.finishTasksAndInvalidate() }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let started: URLSessionDownloadTask = lock.withLock {
          self.continuation = continuation
          let task = session.downloadTask(with: url)
          self.task = task
          return task
        }
        started.resume()
      }
    } onCancel: {
      lock.withLock { task }?.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    onProgress(totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
      finish(.failure(UpdateError.download(status: http.statusCode)))
      return
    }
    guard let destination = lock.withLock({ destination }) else {
      finish(.failure(UpdateError.download(status: 0)))
      return
    }
    // Moved rather than copied, and synchronously: `location` is deleted the
    // moment this method returns.
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      finish(.success(destination))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    // Also called after a successful download, by which point `finish` has
    // already been called and does nothing.
    guard let error else { return }
    finish(.failure(error))
  }

  /// Resumes the continuation once and only once. Both delegate callbacks above
  /// can reach here for the same transfer.
  private func finish(_ result: Result<URL, any Error>) {
    let pending: CheckedContinuation<URL, any Error>? = lock.withLock {
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(with: result)
  }
}

/// What can go wrong between finding a release and having it on disk.
///
/// Each case carries what it needs to say something specific. "The update
/// failed" is the sentence this enum exists to avoid: every one of these has a
/// different cause and a different thing to do about it.
enum UpdateError: Error {
  case download(status: Int)
  case wrongSize(expected: Int, got: Int)
  case checksumMismatch(expected: String, got: String)
  case mountFailed(String)
  case noAppInImage
  case wrongApp(String)
  case signatureBroken(String)

  var sentence: String {
    switch self {
    case let .download(status):
      "The download failed — GitHub answered \(status)."
    case let .wrongSize(expected, got):
      "The download is \(got) bytes where the release says \(expected). It did not arrive whole."
    case .checksumMismatch:
      "The download does not match the checksum GitHub published for it, so it was not installed. "
        + "This is what that check is for: try again, and if it happens twice, download it from "
        + "the releases page by hand."
    case let .mountFailed(detail):
      "The disk image would not mount.\(detail.isEmpty ? "" : " \(detail)")"
    case .noAppInImage:
      "There is no application inside the downloaded disk image."
    case let .wrongApp(name):
      "The disk image contains \(name), which is not Pixel Pilot. Nothing was installed."
    case .signatureBroken:
      "The downloaded copy does not pass macOS's own signature check, so it was not installed."
    }
  }
}
