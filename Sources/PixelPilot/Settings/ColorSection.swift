import PixelPilotCore
import SwiftUI

/// Warmth, per display.
///
/// Applied through the gamma table rather than over DDC even on panels that
/// expose VCP 0x0C. Those implement it as the handful of coarse presets their
/// own menu offers, and having one slider mean "continuous" on one monitor and
/// "four steps" on another would be worse than a consistent mechanism. What the
/// probe is for is telling you what your panel really has, which is the same
/// thing the reported-features card does for everything else.
struct ColorSection: View {
  @Bindable var display: DisplayViewModel

  @Environment(\.motion) private var motion
  @State private var presetGlintCount = 0

  private static let neutralCutoff: Double = 6450

  private var sliderKelvin: Double {
    let raw = display.colorTemperatureKelvin ?? ColorTemperature.neutralKelvin
    return min(KelvinTrack.warmRange.upperBound, max(KelvinTrack.warmRange.lowerBound, raw))
  }

  private var isNeutral: Bool {
    display.colorTemperatureKelvin == nil
  }

  var body: some View {
    PanelCard(title: "Farbwärme & Weißpunkt", systemImage: "thermometer.sun", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        slider

        if display.isFightingSomethingOverColor {
          nightShiftWarning.transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: display.isFightingSomethingOverColor)
    }
    .specularGlintSweep(trigger: presetGlintCount, accent: display.accent)
  }

  private var slider: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text("Farbtemperatur")
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        if let active = display.colorTemperatureKelvin {
          Text("\(Int(active.rounded())) K")
            .font(TypeScale.readout)
            .foregroundStyle(display.accent)
            .contentTransition(.numericText(value: active))
            .animation(motion.effectFast, value: active)
        } else {
          Text("6500 K · Neutral")
            .font(TypeScale.readout)
            .foregroundStyle(.secondary)
        }
      }

      ExpressiveSlider(
        value: Binding(
          get: { sliderKelvin },
          set: { newValue in
            if newValue >= Self.neutralCutoff {
              if display.colorTemperatureKelvin != nil {
                display.setColorTemperature(nil)
              }
            } else {
              display.setColorTemperature(newValue)
            }
          }
        ),
        range: KelvinTrack.warmRange,
        accent: display.accent,
        trackStyle: AnyShapeStyle(KelvinTrack.warmGradient),
        detents: KelvinTrack.warmDetents
      )

      HStack {
        Text("2700 K Kerzenlicht").font(TypeScale.detail).foregroundStyle(.secondary)
        Spacer()
        Text("4500 K Studio").font(TypeScale.detail).foregroundStyle(.secondary)
        Spacer()
        Text("6500 K Neutral").font(TypeScale.detail).foregroundStyle(.secondary)
      }

      HStack(spacing: Layout.tight) {
        ForEach(
          [
            (3500.0, "3500 K Abendglut"),
            (4500.0, "4500 K Leselicht"),
            (5500.0, "5500 K Studio"),
            (6500.0, "6500 K Neutral"),
          ],
          id: \.0
        ) { preset in
          let isSelected = if preset.0 >= Self.neutralCutoff {
            isNeutral
          } else if let active = display.colorTemperatureKelvin {
            abs(active - preset.0) < 60
          } else {
            false
          }
          Button(preset.1) {
            display.setColorTemperature(preset.0 >= Self.neutralCutoff ? nil : preset.0)
            presetGlintCount += 1
            Haptics.detent()
          }
          .buttonStyle(.soft(isSelected ? display.accent : .secondary))
          .controlSize(.small)
        }
      }
      .padding(.top, 2)
    }
  }

  /// Says what is happening instead of quietly losing.
  ///
  /// Night Shift writes the same gamma table this does, so the two overwrite
  /// each other and the last writer wins. There is no public API to read Night
  /// Shift's state — `CBBlueLightClient` is private and is not used here — so
  /// the app watches for its own tables being reset in a burst and reports
  /// that, which is a fact rather than a guess.
  private var nightShiftWarning: some View {
    StatusRow(
      symbol: "exclamationmark.triangle.fill",
      tint: Status.warn,
      title: "Ein anderer Dienst verändert die Farben",
      detail: "Die Farbtabellen wurden \(display.recentColorResets)-mal pro Minute zurückgesetzt. "
        + "Deaktiviere Night Shift oder True Tone für ein ruhiges Bild."
    )
  }
}
