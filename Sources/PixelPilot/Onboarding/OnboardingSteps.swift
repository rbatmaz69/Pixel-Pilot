import PixelPilotCore
import SwiftUI

/// The first run.
///
/// This app asks for two permissions before it can do the thing it exists for,
/// and it has an icon in the menu bar and nowhere else. Without an introduction
/// the first experience is a keyboard key that quietly does nothing, and a
/// System Settings pane arrived at with no explanation of why.
///
/// Four steps, none of them mandatory: every one can be skipped, and the whole
/// thing can be dismissed. An onboarding that has to be completed is a wall.
struct OnboardingFlow: View {
  let model: AppModel
  let onFinish: () -> Void

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var step: Step = .welcome
  @State private var presetName = ""
  @State private var presetSymbol = "sun.max.fill"

  enum Step: Int, CaseIterable {
    case welcome, permissions, displays, preset

    var title: String {
      switch self {
      case .welcome: "Pixel Pilot"
      case .permissions: "Two permissions"
      case .displays: "Your displays"
      case .preset: "One preset to start"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.loose) {
      header

      Group {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .displays: displays
        case .preset: preset
        }
      }
      // Already the app's idiom for swapping content in place.
      .transition(.blurReplace.combined(with: .scale(0.96, anchor: .top)))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      footer
    }
    .padding(Layout.section)
    .frame(width: 560, height: 460)
    .background {
      // The same drifting wash as the main window, and it stops existing with
      // this window — nothing to tear down.
      AmbientBackdrop(accent: theme.tone)
        .frame(height: 300)
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .animation(motion.spatialDefault, value: step)
    .onAppear { model.refreshPermissions() }
  }

  // MARK: - Chrome

  private var header: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      Text(step.title).font(TypeScale.sheetTitle)
      OnboardingProgress(current: step)
    }
  }

  private var footer: some View {
    HStack(spacing: Layout.snug) {
      Button("Skip") { onFinish() }
        .buttonStyle(.soft)

      Spacer()

      if step != .welcome {
        Button("Back") {
          step = Step(rawValue: step.rawValue - 1) ?? .welcome
        }
        .buttonStyle(.soft)
      }

      Button(step == .preset ? "Done" : "Next") {
        if let next = Step(rawValue: step.rawValue + 1) {
          step = next
        } else {
          onFinish()
        }
      }
      .buttonStyle(SoftButtonStyle(isProminent: true))
      .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Steps

  private var welcome: some View {
    HStack(spacing: Layout.section) {
      BreathingMonitor(size: 96)

      VStack(alignment: .leading, spacing: Layout.snug) {
        Text("Brightness, contrast and volume for external displays — the controls macOS "
          + "only gives you for the built-in one.")
          .fixedSize(horizontal: false, vertical: true)
        Text("Pixel Pilot lives in the menu bar. There is no Dock icon and no window "
          + "waiting for you; click the icon whenever you need it.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      // Shared with the settings window rather than written twice, so the
      // reasoning about showing both states lives in one place.
      PermissionRow(
        title: "Accessibility",
        detail: "Lets the brightness keys on your keyboard reach this app.",
        isGranted: model.accessibilityGranted,
        action: model.requestAccessibilityPermission
      )
      PermissionRow(
        title: "Input Monitoring",
        detail: "Needed for keyboards other than Apple's, whose keys macOS does not "
          + "translate on its own.",
        isGranted: model.inputMonitoringGranted,
        action: model.requestInputMonitoringPermission
      )

      CardFooter("Both are optional. Without them the sliders and the menu bar still work — "
        + "only the keyboard keys do not.")
    }
  }

  private var displays: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      if model.displays.isEmpty {
        CharacterfulEmptyState(
          title: "Nothing found yet",
          message: "No external display is answering on the DDC bus. Connect one and it "
            + "will appear here — this window does not need to be reopened."
        ) {
          SearchingRadar(size: 64)
        }
      } else {
        if model.displays.count > 1 {
          DisplayMap(
            displays: model.displays,
            selection: .constant(model.displays.first?.id),
            layoutTick: model.screenLayoutTick
          )
        }

        ForEach(model.displays) { display in
          HStack(spacing: Layout.snug) {
            AccentDot(accent: display.accent, isReady: display.isReady, size: 10)
            VStack(alignment: .leading, spacing: 1) {
              Text(display.name).font(TypeScale.rowTitle)
              Text(display.isBuiltin ? "Built-in" : display.routeDescription)
                .font(TypeScale.detail)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
        }

        if model.displays.count > 1 {
          Button("Show me which is which") { model.identifyDisplays() }
            .buttonStyle(.soft)
            .font(TypeScale.detail.weight(.medium))
        }

        CardFooter("Each display gets its own colour, derived from the panel itself, so the "
          + "same monitor keeps it between launches.")
      }
    }
  }

  private var preset: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      Text("Set your displays how you like them, then capture that as a preset. One click "
        + "brings it back later.")
        .fixedSize(horizontal: false, vertical: true)

      SymbolChipPicker(
        selection: $presetSymbol,
        symbols: ["sun.max.fill", "moon.fill", "film.fill", "desktopcomputer",
                  "gamecontroller.fill", "book.fill", "photo.fill", "eye.fill"],
        accessibilityLabel: "Preset symbol"
      )

      HStack(spacing: Layout.snug) {
        TextField("Name", text: $presetName)
          .textFieldStyle(.roundedBorder)
        Button("Capture") {
          let name = presetName.trimmingCharacters(in: .whitespaces)
          guard !name.isEmpty else { return }
          _ = model.captureCurrentState(name: name, symbolName: presetSymbol)
          presetName = ""
        }
        .buttonStyle(.soft)
        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty
          || model.displays.isEmpty)
      }

      if !model.presetList.isEmpty {
        StatusRow(
          symbol: "checkmark.circle.fill",
          tint: Status.ok,
          title: "\(model.presetList.count) preset\(model.presetList.count == 1 ? "" : "s")",
          detail: model.presetList.map(\.name).joined(separator: ", ")
        )
        .transition(.blurReplace)
      }

      CardFooter("More of them, and the schedule that can apply them by time of day, are in "
        + "Settings.")
    }
    .animation(motion.spatialDefault, value: model.presetList.count)
  }
}

/// The steps, as shapes that morph from a dot to a pill as they are passed.
///
/// A row of numbers would say the same thing and say it as a form. The pill is
/// the same shared-highlight idiom as the segmented picker and the accent
/// swatches, which is what keeps this looking like the rest of the app rather
/// than like a component borrowed from somewhere.
private struct OnboardingProgress: View {
  let current: OnboardingFlow.Step

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Namespace private var marker

  private enum Metrics {
    static let dot: CGFloat = 8
    static let pill: CGFloat = 26
    static let height: CGFloat = 8
  }

  var body: some View {
    HStack(spacing: Layout.tight) {
      ForEach(OnboardingFlow.Step.allCases, id: \.rawValue) { step in
        let isPassed = step.rawValue <= current.rawValue
        MorphingRoundedRectangle(cornerRadius: Metrics.height / 2)
          .fill(isPassed ? AnyShapeStyle(theme.tone.accentFill) : AnyShapeStyle(.quaternary))
          .frame(
            width: isPassed ? Metrics.pill : Metrics.dot,
            height: Metrics.height
          )
          .overlay {
            if step == current {
              MorphingRoundedRectangle(cornerRadius: Metrics.height / 2)
                .strokeBorder(theme.tone, lineWidth: 1.5)
                .matchedGeometryEffect(id: "step", in: marker)
            }
          }
      }
    }
    .animation(motion.spatialDefault, value: current)
    .accessibilityElement()
    .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingFlow.Step.allCases.count)")
  }
}
