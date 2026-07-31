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

  private var isWarmed: Bool { display.colorTemperatureKelvin != nil }

  /// Where the slider sits when it is switched on. Not the neutral point —
  /// turning warmth on and seeing nothing happen reads as broken.
  private static let defaultKelvin: Double = 4500

  var body: some View {
    PanelCard(title: "Colour", systemImage: "thermometer.sun", accent: display.accent) {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Warm this display", isOn: Binding(
          get: { isWarmed },
          set: { display.setColorTemperature($0 ? Self.defaultKelvin : nil) }
        ))

        if isWarmed {
          slider.transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
        }

        if display.isFightingSomethingOverColor {
          nightShiftWarning.transition(.blurReplace)
        }

        probeRow

        CardFooter(isWarmed
          ? "Warmth is applied to the colour tables, so it shows up in screenshots and "
            + "costs a little contrast — the same trade as software dimming."
          : "Off means off: with no warmth set, this display's colour is left exactly as "
            + "macOS hands it over.")
      }
      .animation(motion.spatialDefault, value: isWarmed)
      .animation(motion.spatialDefault, value: display.isFightingSomethingOverColor)
    }
  }

  private var slider: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text("Temperature")
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int((display.colorTemperatureKelvin ?? Self.defaultKelvin).rounded())) K")
          .font(TypeScale.readout)
          .foregroundStyle(display.accent)
          .contentTransition(.numericText(value: display.colorTemperatureKelvin ?? 0))
          .animation(motion.effectFast, value: display.colorTemperatureKelvin)
      }

      ExpressiveSlider(
        value: Binding(
          get: { display.colorTemperatureKelvin ?? Self.defaultKelvin },
          set: { display.setColorTemperature($0) }
        ),
        range: ColorTemperature.range,
        accent: display.accent,
        trackStyle: AnyShapeStyle(Self.kelvinGradient),
        // The neutral point is the one place on this track worth finding
        // again, and the two ends are worth feeling. Quarters of a Kelvin
        // range mean nothing.
        detents: [0, Self.fraction(of: ColorTemperature.neutralKelvin), 1]
      )

      HStack {
        Text("Warm").font(TypeScale.detail).foregroundStyle(.secondary)
        Spacer()
        Text("Neutral").font(TypeScale.detail).foregroundStyle(.secondary)
        Spacer()
        Text("Cool").font(TypeScale.detail).foregroundStyle(.secondary)
      }
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
      title: "Something else is changing the colour too",
      detail: "This display's colour tables have been reset \(display.recentColorResets) times "
        + "in the last minute. Night Shift and True Tone write the same tables, and whichever "
        + "wrote last wins. Turning one of them off will settle it."
    )
  }

  @ViewBuilder
  private var probeRow: some View {
    if display.isProbingColor {
      HStack(spacing: Layout.tight) {
        ProgressView().controlSize(.small)
        Text("Asking the display what colour controls it has…")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }
      .transition(.blurReplace)
    } else if let capabilities = display.colorCapabilities {
      StatusRow(
        symbol: display.hasNativeColorControl ? "checkmark.circle.fill" : "info.circle",
        tint: display.hasNativeColorControl ? Status.ok : nil,
        title: display.hasNativeColorControl
          ? "This panel has its own colour control"
          : "This panel has no colour control of its own",
        detail: nativeDetail(capabilities)
      )
      .transition(.blurReplace)
    }
  }

  private func nativeDetail(_ capabilities: DisplayCapabilities) -> String {
    if display.hasNativeColorControl {
      return "It is not used. Its steps are the coarse presets the monitor's own menu offers, "
        + "and one slider meaning different things on different screens is worse than a "
        + "consistent one."
    }
    if case let .implausible(_, _, reason) = capabilities.support(for: .colorTemperature) {
      return "It answered the colour temperature query, but: \(reason)."
    }
    return "Warmth is done in software, which works on any display."
  }

  // MARK: - The track

  private static func fraction(of kelvin: Double) -> Double {
    let range = ColorTemperature.range
    return (kelvin - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  /// The track, generated by the same maths that drives the hardware.
  ///
  /// That is what makes it a preview rather than a decoration: every stop is a
  /// real white point from `ColorTemperature`, so the colour under the handle
  /// is the colour the screen is about to become. Computed once — a gradient of
  /// 29 stops costs nothing to keep around.
  private static let kelvinGradient: LinearGradient = {
    let stops = stride(from: ColorTemperature.range.lowerBound,
                       through: ColorTemperature.range.upperBound,
                       by: 250).map { kelvin -> Gradient.Stop in
      let point = ColorTemperature.whitePoint(kelvin: kelvin)
      return Gradient.Stop(
        color: Color(red: point.red, green: point.green, blue: point.blue),
        location: fraction(of: kelvin)
      )
    }
    return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
  }()
}
