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
  @State private var action: MediaKeyAction = .brightnessUp

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.normal) {
      Text("Teach a key")
        .font(TypeScale.sheetTitle)

      Picker("This key should", selection: $action) {
        ForEach(MediaKeyAction.allCases) { candidate in
          Label(candidate.displayName, systemImage: candidate.symbolName)
            .tag(candidate)
        }
      }
      .pickerStyle(.menu)

      Divider()

      Group {
        if let press = model.pendingLearnedPress {
          captured(press).transition(.blurReplace)
        } else {
          waiting.transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: model.pendingLearnedPress?.signature)

      Spacer(minLength: 0)

      HStack {
        Button("Cancel", role: .cancel) {
          model.cancelLearningKey()
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        if let press = model.pendingLearnedPress {
          Button("Use this key") {
            model.confirmLearnedKey(as: action)
            isPresented = false
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!verdict(for: press).isAllowed)
        }
      }
    }
    .padding(Layout.loose)
    .frame(width: 440, height: 320)
    // A sheet is a container, not a card, so it takes the container radius —
    // that is what makes the scale read as a hierarchy rather than as four
    // numbers that happen to be near each other.
    .background {
      RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous)
        .fill(.background)
    }
    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusPanel, style: .continuous))
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
        Text("Press the key now.")
          .font(TypeScale.rowTitle)
      }
      Text("Nothing will happen when you press it — the key is only being recorded.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func captured(_ press: HIDMediaKeyMonitor.RawPress) -> some View {
    let verdict = verdict(for: press)

    return VStack(alignment: .leading, spacing: Layout.tight) {
      Label("Key captured", systemImage: "checkmark.circle.fill")
        .foregroundStyle(Status.ok)
        .font(TypeScale.rowTitle)
        .symbolEffect(.bounce, value: press.signature)

      // Showing the raw numbers is the point: on a keyboard using a vendor page
      // this is the only evidence of what the key actually is.
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
          title: verdict.isAllowed ? "Usable, with a caveat" : "Not usable",
          detail: text
        )
      }

      if !verdict.isAllowed {
        Button("Try another key") { model.cancelLearningKey(); model.beginLearningKey() }
          .buttonStyle(.soft)
          .font(TypeScale.detail.weight(.medium))
      }
    }
    .animation(motion.effectDefault, value: press.signature)
  }

  private func verdict(for press: HIDMediaKeyMonitor.RawPress) -> KeyBindability {
    KeyBindingRules.bindability(
      page: press.signature.usagePage, usage: press.signature.usage
    )
  }
}
