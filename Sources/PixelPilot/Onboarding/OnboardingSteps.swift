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
      case .permissions: "Zwei Berechtigungen"
      case .displays: "Deine Displays"
      case .preset: "Erstes Preset"
      }
    }

    var subtitle: String {
      switch self {
      case .welcome:
        "Warm Studio Craft für all deine Bildschirme — ruhig, präzise und mit 0,0 % CPU im Leerlauf."
      case .permissions:
        "Damit die Helligkeits- und Lautstärketasten deiner Tastatur jeden Monitor direkt erreichen."
      case .displays:
        "Jeder Bildschirm erhält seine eigene Studio-Kennfarbe und wird über seinen nativen Kanal gesteuert."
      case .preset:
        "Halte deine aktuelle Lichtstimmung als erste Szene für die Menüleiste fest."
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
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title).font(TypeScale.sheetTitle)
        Text(step.subtitle)
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
      }
      OnboardingProgress(current: step)
    }
  }

  private var footer: some View {
    HStack(spacing: Layout.snug) {
      Button("Überspringen") { onFinish() }
        .buttonStyle(.soft)

      Spacer()

      if step != .welcome {
        Button("Zurück") {
          step = Step(rawValue: step.rawValue - 1) ?? .welcome
        }
        .buttonStyle(.soft)
      }

      Button(step == .preset ? "Fertig" : "Weiter") {
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
        HStack(spacing: 6) {
          AccentDot(accent: Status.ok, isReady: true, size: 7)
          Text("STUDIO-ATELIER · 0,0 % CPU IM LEERLAUF")
            .font(TypeScale.detail.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
        }

        Text("Helligkeit, Kontrast, Farbwärme und Lautstärke für externe Monitore direkt auf Hardware-Ebene.")
          .fixedSize(horizontal: false, vertical: true)
        Text("Pixel Pilot wohnt in der Menüleiste ohne Dock-Symbol — ein Klick genügt.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      PermissionRow(
        title: "Bedienungshilfen",
        detail: "Leitet Helligkeits- und Lautstärketasten deiner Tastatur weiter.",
        isGranted: model.accessibilityGranted,
        action: model.requestAccessibilityPermission
      )
      PermissionRow(
        title: "Eingabeüberwachung",
        detail: "Erkennt Helligkeitstasten auf externen Tastaturen ohne macOS-Übersetzung.",
        isGranted: model.inputMonitoringGranted,
        action: model.requestInputMonitoringPermission
      )

      CardFooter("Beide optional — Regler und Menüleiste funktionieren immer.")
    }
  }

  private var displays: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      if model.displays.isEmpty {
        CharacterfulEmptyState(
          title: "Noch kein externes Display gefunden",
          message: "Schließe einen externen Monitor an — er erscheint automatisch hier."
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
              Text(display.isBuiltin ? "Integriert" : display.routeDescription)
                .font(TypeScale.detail)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
        }

        if model.displays.count > 1 {
          Button("Bildschirme identifizieren") { model.identifyDisplays() }
            .buttonStyle(.soft)
            .font(TypeScale.detail.weight(.medium))
        }

        CardFooter("Jedes Display behält seine persönliche Kennfarbe dauerhaft.")
      }
    }
  }

  private var preset: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      Text("Stimme deine Displays nach Wunsch ab und sichere das Ergebnis als erstes Preset.")
        .fixedSize(horizontal: false, vertical: true)

      SymbolChipPicker(
        selection: $presetSymbol,
        symbols: ["sun.max.fill", "moon.fill", "film.fill", "desktopcomputer",
                  "gamecontroller.fill", "book.fill", "photo.fill", "eye.fill"],
        accessibilityLabel: "Preset-Symbol"
      )

      HStack(spacing: Layout.snug) {
        TextField("Name", text: $presetName)
          .textFieldStyle(.roundedBorder)
        Button("Sichern") {
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
          title: model.presetList.count == 1 ? "1 Preset" : "\(model.presetList.count) Presets",
          detail: model.presetList.map(\.name).joined(separator: ", ")
        )
        .transition(.blurReplace)
      }

      CardFooter("Weitere Szenen und den Tages-Zeitplan findest du in den Einstellungen.")
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
          .fill(isPassed ? AnyShapeStyle(theme.fill(for: theme.tone)) : AnyShapeStyle(.quaternary))
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
