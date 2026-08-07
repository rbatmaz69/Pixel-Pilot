import Foundation
import PixelPilotCore
import UserNotifications

/// Tells the user, once, that a release is out.
///
/// Permission is asked for **the first time an update is actually found**, and
/// never at launch. That ordering is the whole design. Asking on first run
/// would put a system dialog in front of somebody who has just granted
/// Accessibility and Input Monitoring, for an event that may not happen for
/// months — and this app already spends more of a new user's patience on
/// permissions than it would like. Asked at the moment there is something to
/// say, the request explains itself.
///
/// One notification per version. `lastAnnounced` is in memory rather than in
/// preferences on purpose: the app is a menu bar app that runs for weeks, and
/// the check happens at launch, so re-announcing on a later launch of a build
/// that still has not been updated is a reminder rather than a repeat.
@MainActor
final class UpdateNotifier {
  private var lastAnnounced: SemanticVersion?

  static let openUpdatesAction = "dev.rb.pixelpilot.update.open"
  private static let category = "dev.rb.pixelpilot.update"

  func announce(_ release: GitHubRelease, version: SemanticVersion) {
    guard lastAnnounced != version else { return }
    lastAnnounced = version

    Task {
      let center = UNUserNotificationCenter.current()
      // `.provisional` would deliver quietly with no dialog at all, and is
      // tempting. It is not used because a quiet notification in Notification
      // Centre is indistinguishable from no notification for somebody who never
      // opens it, and this is the one message the app ever sends.
      guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
            granted
      else { return }

      center.setNotificationCategories([
        UNNotificationCategory(
          identifier: Self.category,
          actions: [UNNotificationAction(
            identifier: Self.openUpdatesAction,
            title: "Show update",
            options: [.foreground]
          )],
          intentIdentifiers: []
        ),
      ])

      let content = UNMutableNotificationContent()
      content.title = "Pixel Pilot \(version) is available"
      content.body = "You have \(Updater.currentVersionString). Open Settings → Updates to "
        + "install it."
      content.categoryIdentifier = Self.category

      // `nil` trigger delivers immediately. The identifier is the version, so
      // the same release cannot stack up two notifications.
      try? await center.add(UNNotificationRequest(
        identifier: "update-\(version)", content: content, trigger: nil
      ))
    }
  }
}
