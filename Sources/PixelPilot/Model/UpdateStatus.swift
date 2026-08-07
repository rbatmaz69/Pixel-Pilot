import PixelPilotCore
import SwiftUI

/// What the updater's phase looks like, said once.
///
/// This was four private computed properties on `UpdateSettings`. The overview
/// board wants the same line, and a second switch over the same eight cases is
/// a second place for "Ready to install" to end up spelt differently, or for a
/// new phase to be forgotten.
///
/// In the app target rather than in `PixelPilotCore`, because `UpdatePhase` is:
/// it carries a `GitHubRelease` and the URL of a mounted disk image, neither of
/// which the UI-free package has any business knowing about.
@MainActor
struct UpdateStatus {
  let symbol: String
  let tint: Color?
  let title: String
  let detail: String

  init(updater: Updater) {
    symbol = Self.symbol(for: updater.phase)
    tint = Self.tint(for: updater.phase)
    title = Self.title(for: updater.phase)
    detail = Self.detail(for: updater)
  }

  private static func symbol(for phase: UpdatePhase) -> String {
    switch phase {
    case .idle, .checking: "shippingbox"
    case .upToDate: "checkmark.circle.fill"
    case .available: "arrow.down.circle.fill"
    case .downloading, .verifying, .installing: "arrow.down.circle"
    case .readyToInstall: "checkmark.seal.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  private static func tint(for phase: UpdatePhase) -> Color? {
    switch phase {
    case .upToDate, .readyToInstall: Status.ok
    case .available: Status.info
    case .failed: Status.warn
    default: nil
    }
  }

  private static func title(for phase: UpdatePhase) -> String {
    switch phase {
    case .checking: "Asking GitHub…"
    case let .available(release):
      "\(SemanticVersion(release.tag)?.description ?? release.tag) is available"
    case .downloading: "Downloading…"
    case .verifying: "Checking what arrived…"
    case .readyToInstall: "Ready to install"
    case .installing: "Installing…"
    case .upToDate: "Up to date"
    case .failed: "Could not check for updates"
    case .idle: "Version \(Updater.currentVersionString)"
    }
  }

  /// Takes the whole updater rather than the phase, because two of these
  /// sentences need `installCapability` and `lastCheck` as well.
  private static func detail(for updater: Updater) -> String {
    switch updater.phase {
    case let .failed(message):
      return message

    case .readyToInstall:
      return "Downloaded and checked against the checksum GitHub published for it. "
        + "Installing quits the app and opens the new one."

    case let .available(release):
      let published = release.publishedAt.map {
        " Published \($0.formatted(date: .abbreviated, time: .omitted))."
      } ?? ""
      let blocked = updater.installCapability == .notWritable
        ? " This copy is not somewhere it can replace itself — it is at "
          + "\(Bundle.main.bundleURL.deletingLastPathComponent().path), which this app cannot "
          + "write to. Download it from the releases page and put it in Applications by hand."
        : ""
      return "You have \(Updater.currentVersionString)." + published + blocked

    default:
      let version = "Version \(Updater.currentVersionString) (build \(Updater.currentBuildString))."
      guard let last = updater.lastCheck else { return version + " Not checked yet." }
      return version + " Checked \(last.formatted(date: .abbreviated, time: .shortened))."
    }
  }
}
