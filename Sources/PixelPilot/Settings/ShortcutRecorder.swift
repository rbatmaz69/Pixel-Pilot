import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a keyboard shortcut.
///
/// While recording, a local event monitor swallows every key press so the
/// keystroke lands here rather than in the app. Escape cancels and Delete
/// clears, matching how the system's own shortcut fields behave — people try
/// both without being told.
struct ShortcutRecorder: View {
  let shortcut: Shortcut?
  let onChange: (Shortcut?) -> Void

  @Environment(\.motion) private var motion
  @State private var isRecording = false
  @State private var monitor: Any?
  @State private var isHovered = false

  var body: some View {
    Button {
      isRecording ? stopRecording() : startRecording()
    } label: {
      HStack(spacing: 6) {
        Text(label)
          .font(.callout.monospaced())
          .foregroundStyle(isRecording ? .secondary : .primary)

        if shortcut != nil, !isRecording {
          Image(systemName: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .opacity(isHovered ? 1 : 0)
            .animation(motion.effectFast, value: isHovered)
            .transition(.scale.combined(with: .opacity))
            .onTapGesture { onChange(nil) }
        }
      }
      .frame(minWidth: 110)
      .padding(.horizontal, Layout.snug)
      .padding(.vertical, 5)
      .background {
        MorphingRoundedRectangle(cornerRadius: isRecording ? Layout.radiusCard : Layout.radiusControl)
          .fill(isRecording ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary))
      }
      .overlay {
        MorphingRoundedRectangle(cornerRadius: isRecording ? Layout.radiusCard : Layout.radiusControl)
          .stroke(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
          .modifier(RecordingPulse(isRecording: isRecording, isReduced: motion.isReduced))
      }
      .animation(motion.spatialFast, value: isRecording)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .onDisappear(perform: stopRecording)
    .help(isRecording ? "Press a key combination, or Escape to cancel" : "Click to record a shortcut")
  }

  private var label: String {
    if isRecording { return "Press keys…" }
    return shortcut?.displayString ?? "Record"
  }

  private func startRecording() {
    guard !isRecording else { return }
    isRecording = true

    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      guard event.type == .keyDown else { return nil }

      switch Int(event.keyCode) {
      case kVK_Escape:
        stopRecording()
      case kVK_Delete:
        onChange(nil)
        stopRecording()
      default:
        // Nil means the combination had no modifier and would have hijacked an
        // ordinary keystroke system wide. Stay in recording mode and let the
        // user try again.
        if let recorded = Shortcut(event: event) {
          onChange(recorded)
          stopRecording()
        }
      }
      // Consumed either way: a keystroke aimed at the recorder must not also
      // reach the window behind it.
      return nil
    }
  }

  private func stopRecording() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    isRecording = false
  }
}

/// A slow breath on the border while the recorder is armed.
///
/// The one loop in the app whose gate is stricter than "on screen": it runs
/// only while recording, which is a state the user entered deliberately and
/// leaves with the next keystroke. It is also the one place a loop earns its
/// keep — a field that is silently swallowing every key press should not look
/// identical to one that is not.
private struct RecordingPulse: ViewModifier {
  let isRecording: Bool
  let isReduced: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isRecording, !isReduced {
      content.phaseAnimator([0, 1]) { view, phase in
        view.opacity(phase == 0 ? 0.45 : 1)
      } animation: { _ in
        .easeInOut(duration: 0.75)
      }
    } else {
      content
    }
  }
}
