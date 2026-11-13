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
        Toggle("Diesem Display ein Papier-Finish geben", isOn: Binding(
          get: { isFinished },
          set: { display.setToneCurve($0 ? .paper : nil) }
        ))

        if isFinished {
          VStack(alignment: .leading, spacing: Layout.normal) {
            picker
            detailToggle
            if showsDetail {
              sliders.transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
            }
          }
          .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
        }

        CardFooter(isFinished
          ? "Hebt Schwarztöne sanft an und beruhigt Spitzenlichter – wie Tinte auf warmem Papier."
          : "Ohne Finish bleibt die Tonwertkurve exakt wie von macOS vorgegeben.")
      }
      .animation(motion.spatialDefault, value: isFinished)
      .animation(motion.spatialDefault, value: showsDetail)
    }
  }

  /// The three named finishes. Nothing is highlighted once the sliders below
  /// have been moved, and that is the intended reading — the curve is no longer
  /// one of these, and lighting a segment that no longer describes it would be
  /// the picker lying about what the screen is doing.
  private var picker: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      SegmentedMorphPicker(
        selection: Binding(
          get: { curve },
          set: { display.setToneCurve($0) }
        ),
        options: ToneCurve.named.map { (value: $0.curve, title: $0.name) },
        accent: display.accent
      )

      Text(curve.namedFinish.map(describe) ?? "Individuell abgestimmt.")
        .font(TypeScale.editorialAccent)
        .foregroundStyle(.secondary)

      HStack(spacing: Layout.tight) {
        finishMetricPill(label: "Schwarzanhebung", value: "+\(percent(curve.blackLift))")
        finishMetricPill(label: "Weißpunkt-Decke", value: percent(curve.whiteCeiling))
        finishMetricPill(label: "Weichzeichnung", value: String(format: "%.2f", curve.softness))
      }
      .padding(.top, 2)
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
      slider(
        title: "Weißpunkt-Decke",
        value: curve.whiteCeiling,
        range: ToneCurve.ceilingRange,
        readout: percent(curve.whiteCeiling),
        set: { ToneCurve(blackLift: curve.blackLift, whiteCeiling: $0, softness: curve.softness) }
      )
      slider(
        title: "Weichzeichnung",
        value: curve.softness,
        range: ToneCurve.softnessRange,
        readout: String(format: "%.2f", curve.softness),
        set: { ToneCurve(blackLift: curve.blackLift, whiteCeiling: curve.whiteCeiling, softness: $0) }
      )
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
