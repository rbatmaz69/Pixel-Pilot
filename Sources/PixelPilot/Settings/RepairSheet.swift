import PixelPilotCore
import SwiftUI

/// What is about to happen, before it happens.
///
/// **This is why the sheet exists at all.** The warning cannot live on the
/// overlay: by the time the overlay is up, the thing being warned about is
/// already on the screen. So it is here, in a window, with nothing flashing —
/// and the overlay still counts three before it starts.
///
/// There is deliberately **no "don't show this again"**. Every other repeated
/// dialog in an app is worth suppressing; this one's entire value is that it
/// appears every time, because the person who needs it may not be the person
/// who ticked the box.
struct RepairSheet: View {
  let model: AppModel
  let display: DisplayViewModel
  @Binding var isPresented: Bool

  @Environment(\.theme) private var theme

  @State private var style: RepairPlan.Style = .noise
  @State private var intensity: RepairPlan.Intensity = .standard
  @State private var duration: RepairPlan.Duration = .tenMinutes

  /// Honoured rather than ignored, and *said* rather than done quietly — the
  /// argument `OverlayPanel.reduceMotion` already makes: half-honouring an
  /// accessibility setting looks like a broken setting.
  private var isForcedGentle: Bool { OverlayPanel.reduceMotion }

  private var effectiveIntensity: RepairPlan.Intensity {
    isForcedGentle ? .gentle : intensity
  }

  private var marks: [PixelDefect] { display.pixelDefects }
  private var exercisable: [PixelDefect] { PixelDefects.worthExercising(marks) }
  private var isWholeScreen: Bool { exercisable.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Pixel reanimieren")
          .font(TypeScale.sheetTitle)
        Text("Gezieltes Subpixel-Training für träge Flüssigkristalle auf \(display.name).")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
      }

      warning

      ScrollView {
        VStack(alignment: .leading, spacing: Layout.normal) {
          scope

          if isWholeScreen {
            VStack(alignment: .leading, spacing: Layout.tight) {
              Text("Muster").font(TypeScale.rowTitle)
              SegmentedMorphPicker(
                selection: $style,
                options: RepairPlan.Style.allCases.map { ($0, $0.displayName) },
                accent: display.accent
              )
              Text(style.summary)
                .font(TypeScale.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          VStack(alignment: .leading, spacing: Layout.tight) {
            Text("Intensität").font(TypeScale.rowTitle)
            SegmentedMorphPicker(
              selection: Binding(
                get: { effectiveIntensity },
                set: { intensity = $0 }
              ),
              options: RepairPlan.Intensity.allCases.map { ($0, $0.displayName) },
              accent: display.accent
            )
            .disabled(isForcedGentle)
            Text(effectiveIntensity.summary)
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if isForcedGentle {
              StatusRow(
                symbol: "figure.walk.motion",
                tint: Status.info,
                title: "Bewegung reduzieren ist aktiv",
                detail: "Läuft automatisch im sanften Modus gemäß Systemeinstellungen."
              )
            }
          }

          VStack(alignment: .leading, spacing: Layout.tight) {
            Text("Dauer").font(TypeScale.rowTitle)
            SegmentedMorphPicker(
              selection: $duration,
              options: RepairPlan.Duration.allCases.map { ($0, $0.displayName) },
              accent: display.accent
            )
            if duration == .untilStopped {
              StatusRow(
                symbol: "clock.badge.exclamationmark",
                title: "Dauerlauf ohne Zeitlimit",
                detail: "Bei OLED-Panels lange Dauerläufe vermeiden, um Einbrennen vorzubeugen."
              )
            }
          }

          Divider()

          StatusRow(
            symbol: "sun.max",
            title: "Helligkeit vorab aufdrehen",
            detail: "Volle Leuchtkraft unterstützt die Trägheitslösung der Subpixel."
          )

          Text(RepairSheet.honestly)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Layout.tight)
      }
      .scrollContentBackground(.hidden)

      Divider()

      HStack {
        Button("Abbrechen", role: .cancel) { isPresented = false }
          .buttonStyle(.soft)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Starten") {
          model.startRepair(
            on: display,
            style: isWholeScreen ? style : .noise,
            intensity: effectiveIntensity,
            duration: duration
          )
          isPresented = false
        }
        .buttonStyle(.soft(display.accent))
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Layout.loose)
    .frame(width: 480, height: 572)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .fill(theme.surface)
    }
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .strokeBorder(theme.specularRim, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous))
  }

  private var warning: some View {
    StatusRow(
      symbol: "exclamationmark.triangle.fill",
      tint: Status.warn,
      title: "Schnelle Farbwechsel & Blitzmuster",
      detail: "Bei Lichtempfindlichkeit nicht starten. Startet nach 3 Sekunden; Esc stoppt sofort."
    )
  }

  @ViewBuilder
  private var scope: some View {
    if isWholeScreen, marks.isEmpty {
      StatusRow(
        symbol: "rectangle.dashed",
        title: "Gesamter Bildschirm",
        detail: "Keine markierten Bereiche — übt die komplette Fläche."
      )
    } else if isWholeScreen {
      StatusRow(
        symbol: "circle.slash",
        tint: Status.warn,
        title: "Nur tote Pixel markiert",
        detail: "Tote Transistoren reagieren nicht auf Farbwechsel; drücke S auf festsitzenden Pixeln."
      )
    } else {
      StatusRow(
        symbol: "scope",
        tint: Status.ok,
        title: exercisable.count == 1 ? "1 markierte Stelle" : "\(exercisable.count) markierte Stellen",
        detail: "Nur diese Bereiche blitzen, der Rest bleibt dunkel."
      )
    }
  }

  static let honestly =
    "Kann träge oder farbig leuchtende Subpixel befreien; dauerhaft tote Pixel bleiben unverändert."
}
