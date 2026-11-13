import PixelPilotCore
import SwiftUI

/// Whether this screen is alright, and what can be done about it if not.
///
/// Sits directly under Controls, second of the cards, and the order is the
/// argument: the first card answers *what do I want this screen to do*, this
/// one answers *is this screen alright*, and everything below is configuration.
/// The test patterns have always been in the app — folded inside the collapsed
/// Diagnostics card at the bottom, where the only people who found them were
/// the ones already debugging DDC.
///
/// Everything this card claims is bounded. It records what a person saw, it
/// remembers where they saw it, and it can exercise those spots. It does not
/// measure anything, and the repair cannot fix a dead pixel — both said here
/// rather than left for someone to work out after ten minutes of flashing.
struct HealthSection: View {
  let model: AppModel
  @Bindable var display: DisplayViewModel

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var scheme

  @State private var isRepairing = false
  @State private var isClearingMarks = false

  private var marks: [PixelDefect] { display.pixelDefects }

  var body: some View {
    PanelCard(title: "Health", systemImage: "waveform.path.ecg", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        careSealBanner

        if let report = display.healthReport {
          verdict(report).transition(.blurReplace)
        } else {
          neverChecked.transition(.blurReplace)
        }

        actions

        if !marks.isEmpty {
          Divider()
          marksRow.transition(.blurReplace)
        }

        CardFooter(RepairSheet.honestly)
      }
      .animation(motion.spatialDefault, value: marks.count)
      .animation(motion.spatialDefault, value: display.healthReport?.date)
    }
    .sheet(isPresented: $isRepairing) {
      RepairSheet(model: model, display: display, isPresented: $isRepairing)
    }
    .confirmationDialog(
      "Clear the marks on this display?",
      isPresented: $isClearingMarks
    ) {
      Button("Clear", role: .destructive) { model.clearMarks(on: display) }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Naming what is lost rather than asking "are you sure". Finding a single
      // bad pixel again means walking the patterns again.
      Text("The \(marks.count) marked \(marks.count == 1 ? "spot" : "spots") go. "
        + "Reanimating then works the whole screen rather than the spots you found, "
        + "and finding them again means walking the patterns again.")
    }
  }

  /// Warm „In Bestform“ Panel-Fürsorge-Siegel (`.care-seal`) that replaces
  /// sterile diagnostic tables with an appreciative studio care badge.
  private var careSealBanner: some View {
    let sealTint: Color = {
      guard let report = display.healthReport else { return theme.studioAccent }
      return tint(for: report.overall) ?? theme.studioAccent
    }()
    let sealTitle: String = {
      guard let report = display.healthReport else {
        return "Panel-Fürsorge · Bereit zur Prüfung"
      }
      switch report.overall {
      case .clean: return "Panel-Fürsorge · In Bestform"
      case .characteristics: return "Panel-Fürsorge · Charakter-Hinweise"
      case .faults: return "Panel-Fürsorge · Aufmerksamkeit empfohlen"
      case .incomplete: return "Panel-Fürsorge · Teilweise geprüft"
      }
    }()
    let sealSubtitle: String = {
      guard let report = display.healthReport else {
        return "Keine auffälligen Stellen vermerkt — ein kurzer Durchlauf schafft Gewissheit."
      }
      switch report.overall {
      case .clean:
        return "Gleichmäßige Ausleuchtung, saubere Zeichnung und null markierte Pixel."
      case .characteristics:
        return "Typische Panel-Eigenschaften dokumentiert, keine defekten Pixel."
      case .faults:
        return "Markierte Bereiche können gezielt mit dem Reanimations-Zyklus gepflegt werden."
      case .incomplete:
        return "Der letzte Durchlauf wurde vorzeitig beendet."
      }
    }()
    let badgeLabel: String = {
      guard let report = display.healthReport else { return "BEREIT" }
      switch report.overall {
      case .clean: return "IN BESTFORM"
      case .characteristics: return "HINWEIS"
      case .faults: return "PFLEGE"
      case .incomplete: return "OFFEN"
      }
    }()

    return HStack(spacing: Layout.snug) {
      ZStack {
        RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
          .fill(sealTint.opacity(scheme == .dark ? 0.18 : 0.12))
          .frame(width: 34, height: 34)
        RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
          .strokeBorder(sealTint.opacity(0.35), lineWidth: 0.75)
          .frame(width: 34, height: 34)
        Image(systemName: display.healthReport?.overall == .clean ? "checkmark.seal.fill" : "sparkles")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(sealTint)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(sealTitle)
          .font(TypeScale.rowTitle)
          .foregroundStyle(.primary)
        Text(sealSubtitle)
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: Layout.tight)

      Text(badgeLabel)
        .font(TypeScale.detail.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(sealTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Capsule(style: .continuous)
            .fill(sealTint.opacity(scheme == .dark ? 0.16 : 0.10))
        )
    }
    .padding(Layout.snug)
    .background(
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .fill(theme.recessedWell)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
        .strokeBorder(sealTint.opacity(scheme == .dark ? 0.26 : 0.20), lineWidth: 1)
    )
  }

  private var neverChecked: some View {
    StatusRow(
      symbol: "questionmark.circle",
      title: "Never checked",
      detail: "Walking the test patterns takes a couple of minutes and says whether this "
        + "panel has dead or stuck pixels, banding, backlight bleed — or is simply not "
        + "running at its own resolution."
    )
  }

  private func verdict(_ report: HealthReport) -> some View {
    StatusRow(
      symbol: symbol(for: report.overall),
      tint: tint(for: report.overall),
      title: report.overall.displayName,
      detail: "\(report.headline) · checked "
        + report.date.formatted(date: .abbreviated, time: .omitted)
    )
  }

  private func symbol(for verdict: HealthReport.Verdict) -> String {
    switch verdict {
    case .clean: "checkmark.circle.fill"
    case .characteristics: "info.circle.fill"
    case .faults: "exclamationmark.triangle.fill"
    case .incomplete: "clock.badge.questionmark"
    }
  }

  private func tint(for verdict: HealthReport.Verdict) -> Color? {
    switch verdict {
    case .clean: Status.ok
    case .characteristics: Status.info
    case .faults: Status.warn
    case .incomplete: nil
    }
  }

  private var actions: some View {
    HStack(spacing: Layout.snug) {
      Button(display.healthReport == nil ? "Run health check" : "Check again") {
        model.runHealthCheck(on: display)
      }
      .buttonStyle(.soft(display.accent))

      // The ellipsis is not decoration: this one opens a sheet, and the sheet
      // is where the warning is.
      Button("Reanimate stuck pixels…") { isRepairing = true }
        .buttonStyle(.soft)

      Button("Show test patterns") { model.showTestPatterns(on: display) }
        .buttonStyle(.soft)
    }
  }

  private var marksRow: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text(marksTitle).font(TypeScale.rowTitle)
      Text("Marked by hand while the patterns were up, and kept for this monitor — "
        + "as fractions of the screen, so they still point at the same glass after a "
        + "resolution change.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Layout.snug) {
        Button("Show marks") { model.showMarks(on: display) }
          .buttonStyle(.soft(display.accent))
        Button("Clear marks", role: .destructive) { isClearingMarks = true }
          .buttonStyle(.soft)
      }
    }
  }

  private var marksTitle: String {
    let count = marks.count == 1 ? "1 marked area" : "\(marks.count) marked areas"
    let summary = PixelDefects.summary(marks)
    return summary.isEmpty ? count : "\(count) — \(summary)"
  }
}
