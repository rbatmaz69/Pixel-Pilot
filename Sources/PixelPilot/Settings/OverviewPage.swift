import PixelPilotCore
import SwiftUI

/// Everything the app knows about its own state, on one page.
///
/// This page exists because nothing else answers "is everything alright". Each
/// fact it shows already existed and each lived on exactly one page: the health
/// verdict on a display's page, the update state on Updates, the permissions on
/// Keys, the next scheduled change drawn as an arc on Schedule, and the active
/// preset — which was recorded and never shown anywhere at all. Finding out
/// meant opening five pages and knowing to open them.
///
/// **The one page that takes the router**, and that is deliberate rather than
/// convenient: every row here is an answer that belongs somewhere else, and a
/// row that tells you something without being able to take you there is a row
/// that sends you looking. The direction stays one-way — this page writes
/// `router.route` and never reads it back.
///
/// **Nothing here ticks.** The page is built when the route changes and torn
/// down with the window; every value is read once from state that is already
/// observed. The schedule line says "21:00" rather than "in three hours" for
/// that reason — an absolute time is right forever without a timer, and a
/// relative one is wrong within a minute and invites the `TimelineView` that
/// this app does not have. There is no `AmbientBackdrop` either: it belongs to
/// a display's page, where it sits behind that display's single colour, and a
/// board has no one colour to be lit by.
struct OverviewPage: View {
  let model: AppModel
  let router: SettingsRouter

  @Environment(\.motion) private var motion

  var body: some View {
    CardStack {
      displaysCard
      rightNowCard
      permissionsCard
      versionCard
      if !disconnected.isEmpty {
        rememberedCard
      }
    }
    .navigationTitle("Overview")
    // The same call the panel and the Keys page make, for the same reason:
    // opening a surface is a cheap, natural moment to notice a grant that
    // happened while the app was in the background.
    .onAppear {
      model.refreshPermissions()
      model.refreshKnownDisplays()
    }
  }

  // MARK: - Displays

  /// One row per display, **in sidebar order**.
  ///
  /// Not sorted worst-first, which was the obvious alternative. A board whose
  /// rows change places between two openings has to be re-read every time,
  /// and the reading it would buy — "the problem is at the top" — is already
  /// carried by the colour. Severity is a tint here, not a position.
  private var displaysCard: some View {
    PanelCard(title: "Displays", systemImage: "display") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        if model.displays.isEmpty {
          CharacterfulEmptyState(
            title: "Looking for displays",
            message: "Nothing is answering on the DDC bus yet. External monitors appear "
              + "here as soon as they are connected."
          ) {
            SearchingRadar()
          }
        } else {
          ForEach(model.displays) { display in
            StatusRow(
              symbol: display.healthReport?.overall.symbolName
                ?? HealthVerdictAppearance.neverCheckedSymbol,
              // The display's own colour when there is nothing wrong, the
              // severity colour when there is. Identity in the ordinary case —
              // which is what ties this row to the dot in the sidebar, the
              // rectangle in the map and the cards on that display's page —
              // and severity when severity is the point.
              tint: tint(for: display),
              title: display.name,
              detail: display.statusHeadline
            ) {
              Button("Open") { router.route = .display(display.id) }
                .buttonStyle(.soft(display.accent))
                .font(TypeScale.detail.weight(.medium))
            }
          }
        }

        if !model.isDDCAvailable {
          Divider()
          StatusRow(
            symbol: "cable.connector.slash",
            tint: Status.warn,
            title: "DDC/CI is unavailable on this system",
            detail: "Nothing will answer on the bus. Software dimming still works, and is "
              + "what every display here will be using."
          )
        }
      }
      .animation(motion.spatialDefault, value: model.displays.map(\.id))
    }
  }

  private func tint(for display: DisplayViewModel) -> Color {
    switch display.statusLevel {
    case .ok: display.accent
    case .info: Status.info
    case .warn: Status.warn
    case .bad: Status.bad
    }
  }

  // MARK: - Right now

  /// What is currently in force, as three rows that are **always all three**.
  ///
  /// "Nothing is scheduled" has to be as visible as "something is". A card that
  /// only showed the rows with something in them would answer "is a preset
  /// on?" with silence, which is the same silence as the page not knowing.
  private var rightNowCard: some View {
    PanelCard(title: "Right now", systemImage: "bolt.horizontal") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        StatusRow(
          symbol: model.activePreset?.symbolName ?? "square.stack",
          tint: model.activePreset == nil ? nil : Status.info,
          title: model.activePreset?.name ?? "No preset applied",
          detail: model.activePreset == nil
            ? "Presets set every display at once. Nothing has applied one since the app started."
            : "Applied last. A slider moved since then makes this out of date — it is where "
              + "“next preset” carries on from, not a claim about the screens."
        ) {
          link("Presets", to: .app(.presets))
        }

        StatusRow(
          symbol: "app.badge",
          tint: model.activeRule == nil ? nil : Status.info,
          title: ruleTitle,
          detail: "A rule applies a preset when its application comes to the front. "
            + "The fallback covers everything with no rule of its own."
        ) {
          link("Apps", to: .app(.apps))
        }

        StatusRow(
          symbol: "clock",
          tint: model.nextScheduledChange == nil ? nil : Status.info,
          title: scheduleTitle,
          detail: model.nextScheduledChange == nil
            ? "Nothing is scheduled, and nothing is waiting either."
            : "Nothing runs in between — one wake-up is scheduled, and that is all."
        ) {
          link("Schedule", to: .app(.schedule))
        }
      }
      .animation(motion.spatialDefault, value: model.lastAppliedPresetID)
      .animation(motion.spatialDefault, value: model.activeRule)
    }
  }

  private var ruleTitle: String {
    guard let rule = model.activeRule else { return "No per-app rule in force" }
    let preset = model.presetList.first { $0.id == rule.presetID }?.name ?? "a deleted preset"
    guard let appName = rule.appName else {
      return "Nothing matches — the fallback preset “\(preset)” is in force"
    }
    return "\(appName) is using “\(preset)”"
  }

  /// Absolute, and computed once. See the note on the type.
  private var scheduleTitle: String {
    guard let date = model.nextScheduledChange else { return "No schedule" }
    let time = date.formatted(date: .omitted, time: .shortened)
    guard let stop = model.nextScheduledStop else { return "Next change \(time)" }
    return "Next change \(time) · \(model.summary(of: stop))"
  }

  // MARK: - Permissions and keys

  /// The same two `PermissionRow`s the Keys page shows, on purpose.
  ///
  /// Copying the component rather than summarising it is what stops the two
  /// pages disagreeing about whether something is granted, and it means the
  /// "Open Settings…" button is here too — a board that reports a missing
  /// permission and cannot do anything about it is a board that sends you
  /// somewhere else to press the same button.
  private var permissionsCard: some View {
    PanelCard(title: "Permissions and keys", systemImage: "lock.shield") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        PermissionRow(
          title: "Accessibility",
          detail: "Needed to see the keys at all.",
          isGranted: model.accessibilityGranted,
          action: model.requestAccessibilityPermission
        )
        PermissionRow(
          title: "Input Monitoring",
          detail: "Needed for brightness keys on keyboards other than Apple's.",
          isGranted: model.inputMonitoringGranted,
          action: model.requestInputMonitoringPermission
        )

        if model.needsRelaunchForPermissions {
          StatusRow(
            symbol: "arrow.clockwise.circle.fill",
            tint: Status.info,
            title: "Restart to finish enabling",
            detail: "The permission is granted, but this running copy was already refused. "
              + "macOS only re-checks when the app starts."
          ) {
            Button("Restart") { model.relaunch() }
              .buttonStyle(.soft(Status.info))
              .font(TypeScale.detail.weight(.medium))
          }
          .transition(.blurReplace)
        }

        Divider()

        // What is actually running, which is a different question from what
        // has been granted — a permission can be given and the listener still
        // be dead until a relaunch.
        StatusRow(
          symbol: keysSymbol,
          tint: keysTint,
          title: keysTitle,
          detail: "The brightness and volume keys are intercepted and acted on. Apple's own "
            + "keyboards go through the event tap; others need the HID watch."
        ) {
          link("Keys", to: .app(.keys))
        }
      }
      .animation(motion.spatialDefault, value: model.needsRelaunchForPermissions)
    }
  }

  private var keysListening: Bool { model.mediaKeysActive || model.hidKeysActive }

  private var keysSymbol: String {
    keysListening ? "keyboard.badge.eye" : "keyboard.badge.exclamationmark"
  }

  private var keysTint: Color? { keysListening ? Status.ok : Status.warn }

  private var keysTitle: String {
    switch (model.mediaKeysActive, model.hidKeysActive) {
    case (true, true): "Listening to the keys, Apple and otherwise"
    case (true, false): "Listening to the keys through the event tap"
    case (false, true): "Listening to the keys through the HID watch"
    case (false, false): "Not listening to any keys"
    }
  }

  // MARK: - Version

  /// No `check()` on appear.
  ///
  /// The Updates page does check when it opens, and that is fine there: opening
  /// it is asking. This page is what the window opens on, so a network request
  /// from here would be one made every time the window is opened, for a
  /// question nobody asked. The row shows what the last check found.
  private var versionCard: some View {
    PanelCard(title: "Version", systemImage: "shippingbox") {
      let status = UpdateStatus(updater: model.updater)
      StatusRow(
        symbol: status.symbol,
        tint: status.tint,
        title: status.title,
        detail: status.detail
      ) {
        link("Updates", to: .app(.updates))
      }
    }
  }

  // MARK: - Remembered

  private var disconnected: [(key: DisplayKey, settings: DisplaySettings)] {
    model.knownDisplays.filter { !model.isConnected($0.key) }
  }

  /// Capped at four, with a count for the rest.
  ///
  /// The full list is one click away, and a board that scrolls has stopped
  /// being a board — the whole claim of this page is that it can be taken in
  /// at once.
  private var rememberedCard: some View {
    PanelCard(title: "Remembered but not connected", systemImage: "externaldrive.badge.checkmark") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        ForEach(disconnected.prefix(4), id: \.key) { known in
          StatusRow(
            symbol: "display.trianglebadge.exclamationmark",
            title: known.settings.lastKnownName.isEmpty
              ? "An unnamed display"
              : known.settings.lastKnownName,
            detail: "Its settings are kept and come back with it."
          )
        }

        if disconnected.count > 4 {
          Text("and \(disconnected.count - 4) more")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }

        HStack {
          Spacer()
          link("Remembered", to: .remembered)
        }
      }
    }
  }

  // MARK: - Going somewhere

  private func link(_ title: String, to route: SettingsRoute) -> some View {
    Button(title) { router.route = route }
      .buttonStyle(.soft)
      .font(TypeScale.detail.weight(.medium))
  }
}
