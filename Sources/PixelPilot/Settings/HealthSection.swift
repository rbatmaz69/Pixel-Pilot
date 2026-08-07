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

  @State private var isRepairing = false
  @State private var isClearingMarks = false

  private var marks: [PixelDefect] { display.pixelDefects }

  var body: some View {
    PanelCard(title: "Health", systemImage: "waveform.path.ecg", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
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

  private var neverChecked: some View {
    StatusRow(
      symbol: HealthVerdictAppearance.neverCheckedSymbol,
      title: "Never checked",
      detail: "Walking the test patterns takes a couple of minutes and says whether this "
        + "panel has dead or stuck pixels, banding, backlight bleed — or is simply not "
        + "running at its own resolution."
    )
  }

  /// The symbol and tint come from `HealthVerdictAppearance` rather than from a
  /// switch here, because the overview board draws the same verdict and the two
  /// must not disagree about what a fault looks like.
  private func verdict(_ report: HealthReport) -> some View {
    StatusRow(
      symbol: report.overall.symbolName,
      tint: report.overall.tint,
      title: report.overall.displayName,
      detail: "\(report.headline) · checked "
        + report.date.formatted(date: .abbreviated, time: .omitted)
    )
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
