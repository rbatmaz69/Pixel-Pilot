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
    PanelCard(title: "Finish", systemImage: "doc.plaintext", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Give this display a paper finish", isOn: Binding(
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
          ? "This reshapes the colour tables — blacks lift, white comes down — which is what a "
            + "matte panel does to an image and what ink does on paper. It does not remove "
            + "reflections: those come from the glass, and no software reaches them. Like "
            + "warmth, it shows up in screenshots."
          : "Off means off: with no finish set, this display's tone curve is left exactly as "
            + "macOS hands it over.")
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

      Text(curve.namedFinish.map(describe) ?? "Adjusted by hand.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
    }
  }

  private func describe(_ name: String) -> String {
    switch name {
    case "Paper": "Whites settle and blacks lift just enough to stop reading as a hole."
    case "Matte": "More of the same, near what a matte coating does to the picture."
    case "Ink": "The flattest of the three — closer to e-paper than to a display."
    default: ""
    }
  }

  private var detailToggle: some View {
    Button {
      showsDetail.toggle()
    } label: {
      Label(
        showsDetail ? "Hide the numbers" : "Adjust the numbers",
        systemImage: showsDetail ? "chevron.up" : "chevron.down"
      )
      .font(TypeScale.detail)
    }
    .buttonStyle(.soft)
  }

  private var sliders: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      slider(
        title: "Black lift",
        value: curve.blackLift,
        range: ToneCurve.liftRange,
        readout: percent(curve.blackLift),
        set: { ToneCurve(blackLift: $0, whiteCeiling: curve.whiteCeiling, softness: curve.softness) }
      )
      slider(
        title: "White ceiling",
        value: curve.whiteCeiling,
        range: ToneCurve.ceilingRange,
        readout: percent(curve.whiteCeiling),
        set: { ToneCurve(blackLift: curve.blackLift, whiteCeiling: $0, softness: curve.softness) }
      )
      slider(
        title: "Softness",
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
