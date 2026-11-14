import PixelPilotCore
import SwiftUI

/// How the display's tone curve is shaped, per display.
///
/// The sibling of `ColorSection`, and deliberately separate from it. Warmth
/// answers *what colour* the light is; this answers *how the picture sits
/// between black and white*. Folding them together — a "Paper" finish that
/// quietly also warmed the screen — would be two things on one control with the
/// second one unlabelled, which is the same argument `ColorTemperature` makes
/// about not letting warmth double as a brightness control. Someone who wants
/// paper *and* warm has both here, one press apart.
///
/// The card is careful about what it claims. It cannot make a glossy panel
/// matte; gloss is the coating and nothing on the GPU reaches it. What it does
/// is real and is most of the effect: a matte surface scatters ambient light
/// into its own blacks, so they sit higher and the peak white sits lower, and
/// that is a curve this can reproduce exactly.
struct FinishSection: View {
  @Bindable var display: DisplayViewModel

  @Environment(\.motion) private var motion

  @State private var showsDetail = false

  private var isFinished: Bool { display.toneCurve != nil }

  private var curve: ToneCurve { display.toneCurve ?? .paper }

  var body: some View {
    PanelCard(title: "Papier- & Matt-Finish", systemImage: "doc.plaintext", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        SegmentedMorphPicker(
          selection: Binding(
            get: { display.toneCurve },
            set: { display.setToneCurve($0) }
          ),
          options: [
            (nil as ToneCurve?, "Aus"),
            (ToneCurve.paper, "Paper"),
            (ToneCurve.matte, "Matte"),
            (ToneCurve.ink, "Ink"),
          ],
          accent: display.accent
        )

        if let active = display.toneCurve {
          VStack(alignment: .leading, spacing: Layout.normal) {
            Text(active.namedFinish.map(describe) ?? "Individuell abgestimmt.")
              .font(TypeScale.editorialAccent)
              .foregroundStyle(.secondary)

            HStack(spacing: Layout.tight) {
              finishMetricPill(label: "Schwarzanhebung", value: "+\(percent(active.blackLift))")
              finishMetricPill(label: "Weißpunkt-Decke", value: percent(active.whiteCeiling))
              finishMetricPill(label: "Weichzeichnung", value: String(format: "%.2f", active.softness))
            }

            detailToggle

            if showsDetail {
              sliders.transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
            }
          }
          .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
        } else {
          Text("Unveränderte Tonwertkurve — wähle Paper, Matte oder Ink für weniger Spiegel-Kontrast.")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
      }
      .animation(motion.spatialDefault, value: isFinished)
      .animation(motion.tactileSnap ?? motion.spatialDefault, value: showsDetail)
    }
  }

  private func finishMetricPill(label: String, value: String) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
      Text(value)
        .font(TypeScale.detail.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(display.accent)
        .contentTransition(.numericText())
        .animation(motion.effectFast, value: value)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
        .fill(display.accent.opacity(0.08))
    )
  }

  private func describe(_ name: String) -> String {
    switch name {
    case "Paper": "Sanftere Weißtöne und leicht angehobene Schatten für entspanntes Lesen."
    case "Matte": "Ausgewogene Mattierung wie bei einer entspiegelten Studio-Oberfläche."
    case "Ink": "Maximale Ruhe im Kontrast – fast wie elektronisches Papier."
    default: ""
    }
  }

  private var detailToggle: some View {
    Button {
      showsDetail.toggle()
    } label: {
      Label(
        showsDetail ? "Werte ausblenden" : "Schwarzwert & Weißpunkt feinabstimmen",
        systemImage: showsDetail ? "chevron.up" : "chevron.down"
      )
      .font(TypeScale.detail)
    }
    .buttonStyle(.soft)
  }

  private var sliders: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      slider(
        title: "Schwarzanhebung",
        value: curve.blackLift,
        range: ToneCurve.liftRange,
        readout: percent(curve.blackLift),
        set: { ToneCurve(blackLift: $0, whiteCeiling: curve.whiteCeiling, softness: curve.softness) }
      )
      .entrance(index: 0)
      slider(
        title: "Weißpunkt-Decke",
        value: curve.whiteCeiling,
        range: ToneCurve.ceilingRange,
        readout: percent(curve.whiteCeiling),
        set: { ToneCurve(blackLift: curve.blackLift, whiteCeiling: $0, softness: curve.softness) }
      )
      .entrance(index: 1)
      slider(
        title: "Weichzeichnung",
        value: curve.softness,
        range: ToneCurve.softnessRange,
        readout: String(format: "%.2f", curve.softness),
        set: { ToneCurve(blackLift: curve.blackLift, whiteCeiling: curve.whiteCeiling, softness: $0) }
      )
      .entrance(index: 2)
    }
  }

  private func slider(
    title: String,
    value: Double,
    range: ClosedRange<Double>,
    readout: String,
    set: @escaping (Double) -> ToneCurve
  ) -> some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        Text(readout)
          .font(TypeScale.readout)
          .foregroundStyle(display.accent)
          .contentTransition(.numericText(value: value))
          .animation(motion.effectFast, value: value)
      }

      ExpressiveSlider(
        value: Binding(get: { value }, set: { display.setToneCurve(set($0)) }),
        range: range,
        accent: display.accent,
        // No detents. They are fractions of a track, and these three tracks are
        // not percentages of anything the quarters would mean something on —
        // the marks that matter here are the named finishes, which are a press
        // away above.
        detents: []
      )
    }
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}
