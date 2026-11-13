import PixelPilotCore
import SwiftUI

/// What the walk found, on the screen it was walked on.
///
/// Shown here rather than only back in the settings window because the answer
/// belongs next to the thing it is about — and because after eleven full-screen
/// patterns, being dropped back to the desktop with no word about what any of
/// it meant would be the wrong ending.
///
/// The background is mid grey rather than the theme's: this is still the
/// display under test, and a summary drawn over the app's own colours would be
/// the first thing since the overlay opened that was not.
struct HealthSummaryView: View {
  let report: HealthReport
  let displayName: String
  let onClose: () -> Void

  var body: some View {
    ZStack {
      Color(.sRGB, white: 0.5, opacity: 1)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)

      VStack(alignment: .leading, spacing: Layout.normal) {
        HStack(spacing: Layout.snug) {
          Image(systemName: report.overall == .clean ? "checkmark.seal.fill" : "sparkles")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(report.overall == .clean ? Status.ok : Status.info)
          VStack(alignment: .leading, spacing: Layout.hair) {
            Text(displayName)
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
            Text(report.overall.displayName)
              .font(TypeScale.sheetTitle)
            Text(report.headline)
              .font(TypeScale.editorialAccent)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: Layout.tight) {
          ForEach(TestPattern.allCases) { pattern in
            row(for: pattern)
          }
        }

        if report.defectCount > 0 {
          Divider()
          Text(marksLine)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        HStack {
          Button("Fertig", action: onClose)
            .buttonStyle(PlateButtonStyle(ink: .primary))
          Text("Esc oder klicken zum Schließen")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
      }
      .padding(Layout.loose)
      .frame(maxWidth: 520, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusPanel))
      .overlay {
        RoundedRectangle(cornerRadius: Layout.radiusPanel)
          .strokeBorder(.separator, lineWidth: 1)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(report.overall.displayName). \(report.headline)")
  }

  private func row(for pattern: TestPattern) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Layout.snug) {
      Image(systemName: symbol(for: report[pattern]))
        .foregroundStyle(tint(for: report[pattern]) ?? .secondary)
        .frame(width: 16)
      Text(pattern.title)
        .font(TypeScale.detail)
        .frame(width: 170, alignment: .leading)
      Text(detail(for: pattern))
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func symbol(for verdict: HealthReport.PatternVerdict) -> String {
    switch verdict {
    case .looksRight: "checkmark.circle.fill"
    case .problem: "exclamationmark.triangle.fill"
    case .skipped: "minus.circle"
    }
  }

  private func tint(for verdict: HealthReport.PatternVerdict) -> Color? {
    switch verdict {
    case .looksRight: Status.ok
    case .problem: Status.warn
    case .skipped: nil
    }
  }

  /// What a flagged pattern *means*, rather than repeating that it was flagged.
  /// Three different answers wear the same warning triangle, and the difference
  /// between them is the entire value of having walked the patterns.
  private func detail(for pattern: TestPattern) -> String {
    switch report[pattern] {
    case .looksRight: "Sieht sauber aus"
    case .skipped: "Übersprungen"
    case .problem:
      switch pattern.problemClass {
      case .pixelFault: "Panel-Pixelstelle — kann markiert und geübt werden."
      case .panelQuality: "Typische Panel-Eigenschaft."
      case .configuration: "Skalierungs-Auflösung weicht ab (Systemeinstellungen ▸ Displays)."
      }
    }
  }

  private var marksLine: String {
    let count = report.defectCount == 1 ? "1 Stelle wurde markiert" : "\(report.defectCount) Stellen wurden markiert"
    return "\(count) — trainierbar unter Panel-Pflege."
  }
}
