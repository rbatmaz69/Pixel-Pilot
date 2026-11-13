import PixelPilotCore
import SwiftUI

/// Whether there is a newer version, and what installing it will cost.
///
/// The last card on this page is the reason the page needs prose at all. This
/// app is signed ad-hoc, so every release has a different signature, and macOS
/// ties the Accessibility grant to the signature — meaning an update always
/// takes away the permission that makes the brightness keys work. An updater
/// that installed quietly and left the user with an app whose main feature had
/// stopped would be worse than no updater, so the cost is stated before the
/// button and again after the restart.
struct UpdateSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion
  @Environment(\.openURL) private var openURL

  private var updater: Updater { model.updater }

  var body: some View {
    CardStack {
      versionCard.entrance(index: 0)
      if let release = releaseOnOffer {
        notesCard(release).entrance(index: 1)
      }
      automaticCard.entrance(index: 2)
      accessibilityCard.entrance(index: 3)
    }
    .animation(motion.spatialDefault, value: updater.phase)
    // Respects the once-a-day rule, so opening this page repeatedly is free.
    // "Check now" below is the way to insist.
    .onAppear { updater.check() }
  }

  /// The release the page is currently about, at whatever stage.
  private var releaseOnOffer: GitHubRelease? {
    switch updater.phase {
    case let .available(release),
         let .downloading(release, _),
         let .verifying(release),
         let .readyToInstall(release, _):
      release
    default:
      nil
    }
  }

  // MARK: - This version

  private var versionCard: some View {
    PanelCard(title: "Aktuelle Version", systemImage: "shippingbox") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Text("Geprüfte Releases direkt von GitHub — ohne Hintergrund-Daemon und mit 0,0 % Idle-CPU.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)

        StatusRow(
          symbol: statusSymbol,
          tint: statusTint,
          title: statusTitle,
          detail: statusDetail
        )

        if case let .downloading(_, fraction) = updater.phase {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(Status.info)
        }

        HStack(spacing: Layout.tight) {
          actions
        }
      }
    }
  }

  @ViewBuilder
  private var actions: some View {
    switch updater.phase {
    case let .available(release):
      switch updater.installCapability {
      case .canInstall:
        Button("\(SemanticVersion(release.tag)?.description ?? release.tag) laden") {
          updater.download(release)
        }
        .buttonStyle(SoftButtonStyle(isProminent: true))
      case .notWritable:
        Button("Release-Seite öffnen") { openURL(release.pageURL) }
          .buttonStyle(.soft)
      }
      Button("Überspringen") { updater.skip(release) }
        .buttonStyle(.soft)

    case let .downloading(_, fraction):
      Text("\(Int(fraction * 100))%")
        .font(TypeScale.readout)
        .foregroundStyle(.secondary)
      Button("Stopp") { updater.cancel() }
        .buttonStyle(.soft)

    case .verifying:
      Button("Stopp") { updater.cancel() }
        .buttonStyle(.soft)

    case let .readyToInstall(release, app):
      Button("Installieren & neu starten") {
        updater.install(release, from: app) { model.quitForHandoff() }
      }
      .buttonStyle(SoftButtonStyle(isProminent: true))
      Button("Später") { updater.cancel() }
        .buttonStyle(.soft)

    case .checking, .installing:
      ProgressView().controlSize(.small)

    default:
      Button("Jetzt prüfen") { updater.check(force: true) }
        .buttonStyle(.soft)
      if let skipped = updater.skippedVersion {
        Button("\(skipped) nicht mehr überspringen") {
          updater.unskip()
          updater.check(force: true)
        }
        .buttonStyle(.soft)
      }
    }
  }

  private var statusSymbol: String {
    switch updater.phase {
    case .idle, .checking: "shippingbox"
    case .upToDate: "checkmark.circle.fill"
    case .available: "arrow.down.circle.fill"
    case .downloading, .verifying, .installing: "arrow.down.circle"
    case .readyToInstall: "checkmark.seal.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  private var statusTint: Color? {
    switch updater.phase {
    case .upToDate, .readyToInstall: Status.ok
    case .available: Status.info
    case .failed: Status.warn
    default: nil
    }
  }

  private var statusTitle: String {
    switch updater.phase {
    case .checking: "Suche auf GitHub…"
    case let .available(release):
      "Version \(SemanticVersion(release.tag)?.description ?? release.tag) verfügbar"
    case .downloading: "Wird geladen…"
    case .verifying: "Wird überprüft…"
    case .readyToInstall: "Bereit zur Installation"
    case .installing: "Installiert…"
    case .upToDate: "Aktuell"
    case .failed: "Update-Prüfung fehlgeschlagen"
    case .idle: "Version \(Updater.currentVersionString)"
    }
  }

  private var statusDetail: String {
    switch updater.phase {
    case let .failed(message):
      return message

    case .readyToInstall:
      return "Geladen und per Prüfsumme verifiziert. Startet die App beim Installieren neu."

    case let .available(release):
      let published = release.publishedAt.map {
        " Veröffentlicht am \($0.formatted(date: .abbreviated, time: .omitted))."
      } ?? ""
      let blocked = updater.installCapability == .notWritable
        ? " Schreibgeschützter Ort (\(Bundle.main.bundleURL.deletingLastPathComponent().path)) — bitte manuell in Programme kopieren."
        : ""
      return "Installiert: \(Updater.currentVersionString)." + published + blocked

    default:
      let version = "Version \(Updater.currentVersionString) (Build \(Updater.currentBuildString))."
      guard let last = updater.lastCheck else { return version + " Noch nicht geprüft." }
      return version + " Geprüft: \(last.formatted(date: .abbreviated, time: .shortened))."
    }
  }

  // MARK: - What is new

  private func notesCard(_ release: GitHubRelease) -> some View {
    PanelCard(title: release.name ?? "Neuerungen", systemImage: "text.alignleft") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        if let notes = Self.readableNotes(release.body) {
          Text(notes)
            .font(TypeScale.detail)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button("Release-Hinweise auf GitHub lesen") { openURL(release.pageURL) }
          .buttonStyle(.soft)
      }
    }
  }

  /// The release body, as much of it as belongs on a card.
  ///
  /// The notes generated by `Scripts/release.sh` open with installation
  /// instructions — a centred image, the Gatekeeper steps, the alert blocks —
  /// all of which are for somebody who does not have the app yet. The person
  /// reading this card has it open. So the boilerplate is cut at the changelog
  /// heading GitHub appends, and what is left is the part that is actually news.
  ///
  /// Rendered through `AttributedString`'s markdown parser rather than shown
  /// raw, so `**bold**` reads as bold. Its inline-only mode is deliberate: full
  /// markdown here would mean headings and lists laying themselves out inside a
  /// card sized for a paragraph.
  static func readableNotes(_ body: String?) -> AttributedString? {
    guard let body, !body.isEmpty else { return nil }

    var text = body
    if let changelog = text.range(of: "## What's Changed") {
      text = String(text[changelog.upperBound...])
    }
    // Drop the HTML header block and the install steps; neither renders as
    // markdown and neither is news.
    let lines = text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .drop { $0.hasPrefix("<") || $0.isEmpty }
      .filter { !$0.hasPrefix("<") }
      .prefix(20)

    let trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    return try? AttributedString(
      markdown: trimmed,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )
  }

  // MARK: - Automatic checks

  private var automaticCard: some View {
    PanelCard(title: "Automatische Prüfung", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        Toggle("Automatisch nach Updates suchen", isOn: Binding(
          get: { updater.automaticChecks },
          set: { updater.automaticChecks = $0 }
        ))

        CardFooter("Einmal täglich beim Öffnen — ohne Hintergrund-Timer (0,0 % Idle-Last).")
      }
    }
  }

  private var accessibilityCard: some View {
    PanelCard(title: "Hinweis zu Ad-hoc-Updates", systemImage: "hand.raised") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        StatusRow(
          symbol: "key.slash",
          tint: Status.warn,
          title: "Bedienungshilfen ggf. neu freigeben",
          detail: "Bei signaturändernden Releases unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen kurz neu hinzufügen."
        )

        Button("Tasten & Fokus öffnen") { model.showKeysSettings() }
          .buttonStyle(.soft)

        CardFooter("Bei lokalen Xcode-Builds bleibt die Signatur unverändert erhalten.")
      }
    }
  }
}
