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
      Text("Reanimate stuck pixels")
        .font(TypeScale.sheetTitle)

      warning

      ScrollView {
        VStack(alignment: .leading, spacing: Layout.normal) {
          scope

          if isWholeScreen {
            VStack(alignment: .leading, spacing: Layout.tight) {
              Text("What to show").font(TypeScale.rowTitle)
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
            Text("How hard").font(TypeScale.rowTitle)
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
                title: "Reduce Motion is on",
                detail: "So this runs at the gentle rate. Turning that off in System "
                  + "Settings ▸ Accessibility ▸ Display puts the choice back."
              )
            }
          }

          VStack(alignment: .leading, spacing: Layout.tight) {
            Text("For how long").font(TypeScale.rowTitle)
            SegmentedMorphPicker(
              selection: $duration,
              options: RepairPlan.Duration.allCases.map { ($0, $0.displayName) },
              accent: display.accent
            )
            if duration == .untilStopped {
              StatusRow(
                symbol: "clock.badge.exclamationmark",
                title: "No end to it",
                detail: "On an OLED panel, hours of this is a burn-in question rather "
                  + "than a repair one."
              )
            }
          }

          Divider()

          StatusRow(
            symbol: "sun.max",
            title: "Turn the brightness up first",
            detail: "The cells get more to work with. Left to you rather than done "
              + "automatically: driving the display's own brightness would mean "
              + "putting it back afterwards, across a session that unplugging the "
              + "monitor can end."
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
        Button("Cancel", role: .cancel) { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start") {
          model.startRepair(
            on: display,
            style: isWholeScreen ? style : .noise,
            intensity: effectiveIntensity,
            duration: duration
          )
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(Layout.loose)
    .frame(width: 480, height: 560)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous)
        .fill(.background)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous))
  }

  private var warning: some View {
    StatusRow(
      symbol: "exclamationmark.triangle.fill",
      tint: Status.warn,
      title: "This flashes the screen quickly",
      detail: "If you're photosensitive or prone to seizures, don't run it — and don't "
        + "leave it running where somebody else will walk past the screen. It counts "
        + "three before it starts, and esc stops it at any point."
    )
  }

  @ViewBuilder
  private var scope: some View {
    if isWholeScreen, marks.isEmpty {
      StatusRow(
        symbol: "rectangle.dashed",
        title: "The whole screen",
        detail: "Nothing is marked on this display. Marking the spots first makes this "
          + "a smaller, quieter thing to sit through — and it works the same cells."
      )
    } else if isWholeScreen {
      // The classification is a guess from which pattern somebody was looking
      // at, not a diagnosis — so this says its piece and leaves Start enabled.
      StatusRow(
        symbol: "circle.slash",
        tint: Status.warn,
        title: "Every mark here is a dead pixel",
        detail: "Exercising won't help those: a dead pixel is a transistor that isn't "
          + "switching, and nothing on the screen reaches a transistor. If one of them "
          + "was really stuck, mark it again and press S — then this works those spots "
          + "instead of the whole screen."
      )
    } else {
      StatusRow(
        symbol: "scope",
        tint: Status.ok,
        title: exercisable.count == 1 ? "1 marked spot" : "\(exercisable.count) marked spots",
        detail: "Only those areas flash. The rest of the screen stays dark."
      )
    }
  }

  /// Said here and again on the card, in the same words, because a claim that
  /// changes between two places is a claim nobody can check.
  static let honestly =
    "This sometimes frees a stuck pixel — one lit in the wrong colour, because its cell "
    + "won't relax. It can't do anything for a dead one: that's a transistor that isn't "
    + "switching, and no picture on the screen reaches a transistor. There's no "
    + "manufacturer behind this technique and no study; it's folk practice that works "
    + "often enough to be worth ten minutes and not often enough to promise anything."
}
