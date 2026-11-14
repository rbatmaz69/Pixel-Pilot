import PixelPilotCore
import SwiftUI

/// Captures a media key by listening for it.
///
/// The only way to support a keyboard that uses vendor-specific codes: those
/// cannot be known in advance, only observed. While this is open the HID
/// listener watches every usage page and acts on nothing, so pressing the key
/// teaches it rather than triggering it.
struct KeyLearningSheet: View {
  let model: AppModel
  @Binding var isPresented: Bool

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var action: MediaKeyAction = .brightnessUp

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Taste anlernen")
          .font(TypeScale.sheetTitle)
        Text("Lerne eine Sondertaste deiner Tastatur direkt über den HID-Kanal an.")
          .font(TypeScale.editorialAccent)
          .foregroundStyle(.secondary)
      }

      ControlRow(title: "Funktion der Taste") {
        MorphMenuPicker(title: action.displayName) {
          ForEach(MediaKeyAction.allCases) { candidate in
            Button {
              action = candidate
            } label: {
              Label(candidate.displayName, systemImage: candidate.symbolName)
            }
          }
        }
      }

      Divider()

      Group {
        if let press = model.pendingLearnedPress {
          captured(press)
            .modifier(CaptureStageTransition(isReduced: motion.isReduced))
        } else {
          waiting
            .modifier(CaptureStageTransition(isReduced: motion.isReduced))
        }
      }
      .animation(motion.tactileSnap ?? motion.spatialDefault, value: model.pendingLearnedPress?.signature)

      Spacer(minLength: 0)

      HStack {
        Button("Abbrechen", role: .cancel) {
          model.cancelLearningKey()
          isPresented = false
        }
        .buttonStyle(.soft)
        .keyboardShortcut(.cancelAction)

        Spacer()

        if let press = model.pendingLearnedPress {
          Button("Taste übernehmen") {
            model.confirmLearnedKey(as: action)
            isPresented = false
          }
          .buttonStyle(SoftButtonStyle(isProminent: true))
          .keyboardShortcut(.defaultAction)
          .disabled(!verdict(for: press).isAllowed)
        }
      }
    }
    .padding(Layout.loose)
    .frame(width: 440, height: 332)
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .fill(theme.surface)
    }
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous)
        .strokeBorder(theme.specularRim, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusWindow, style: .continuous))
    .onAppear { model.beginLearningKey() }
    .onDisappear { model.cancelLearningKey() }
  }

  private var waiting: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(spacing: Layout.tight) {
        // A breathing keyboard rather than a spinner. Nothing is loading here —
        // the app is listening, and a progress indicator says the wrong thing
        // about who is waiting for whom.
        Image(systemName: "keyboard")
          .font(.title3)
          .foregroundStyle(.tint)
          .symbolEffect(.breathe, isActive: !motion.isReduced)
        Text("Drücke jetzt die gewünschte Taste.")
          .font(TypeScale.rowTitle)
      }
      Text("Die Taste wird nur aufgezeichnet und löst noch nichts aus.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func captured(_ press: HIDMediaKeyMonitor.RawPress) -> some View {
    let verdict = verdict(for: press)

    return VStack(alignment: .leading, spacing: Layout.tight) {
      Label("Taste erkannt", systemImage: "checkmark.circle.fill")
        .foregroundStyle(Status.ok)
        .font(TypeScale.rowTitle)
        .symbolEffect(.bounce, value: press.signature)

      Text("\(press.deviceName) — \(press.signature.description)")
        .font(TypeScale.mono)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      switch verdict {
      case .allowed:
        EmptyView()
      case let .allowedWithWarning(text), let .rejected(text):
        StatusRow(
          symbol: verdict.isAllowed ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
          tint: verdict.isAllowed ? Status.warn : Status.bad,
          title: verdict.isAllowed ? "Mit Hinweis verwendbar" : "Nicht verwendbar",
          detail: text
        )
      }

      if !verdict.isAllowed {
        Button("Andere Taste wählen") { model.cancelLearningKey(); model.beginLearningKey() }
          .buttonStyle(.soft)
          .font(TypeScale.detail.weight(.medium))
      }
    }
    .animation(motion.tactileSnap ?? motion.effectDefault, value: press.signature)
  }

  private struct CaptureStageTransition: ViewModifier {
    let isReduced: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
      if isReduced {
        content.transition(.opacity)
      } else {
        content.transition(.blurReplace.combined(with: .scale(0.97, anchor: .center)))
      }
    }
  }

  private func verdict(for press: HIDMediaKeyMonitor.RawPress) -> KeyBindability {
    KeyBindingRules.bindability(
      page: press.signature.usagePage, usage: press.signature.usage
    )
  }
}
