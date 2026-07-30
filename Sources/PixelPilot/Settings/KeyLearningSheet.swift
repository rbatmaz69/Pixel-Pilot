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
    VStack(alignment: .leading, spacing: 16) {
      Text("Teach a key")
        .font(.headline)

      Picker("This key should", selection: $action) {
        ForEach(MediaKeyAction.allCases) { candidate in
          Label(candidate.displayName, systemImage: candidate.symbolName)
            .tag(candidate)
        }
      }
      .pickerStyle(.menu)

      Divider()

      if let press = model.pendingLearnedPress {
        captured(press)
      } else {
        waiting
      }

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
    .padding(20)
    .frame(width: 420, height: 300)
    .onAppear { model.beginLearningKey() }
    .onDisappear { model.cancelLearningKey() }
  }

  private var waiting: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Press the key now.")
          .font(.callout.weight(.medium))
      }
      Text("Nothing will happen when you press it — the key is only being recorded.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func captured(_ press: HIDMediaKeyMonitor.RawPress) -> some View {
    let verdict = verdict(for: press)

    return VStack(alignment: .leading, spacing: 8) {
      Label("Key captured", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.callout.weight(.medium))

      // Showing the raw numbers is the point: on a keyboard using a vendor page
      // this is the only evidence of what the key actually is.
      Text("\(press.deviceName) — \(press.signature.description)")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      switch verdict {
      case .allowed:
        EmptyView()
      case let .allowedWithWarning(text), let .rejected(text):
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: verdict.isAllowed
            ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
            .foregroundStyle(verdict.isAllowed ? Color.orange : .red)
            .font(.caption)
          Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !verdict.isAllowed {
        Button("Try another key") { model.cancelLearningKey(); model.beginLearningKey() }
          .font(.caption)
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
