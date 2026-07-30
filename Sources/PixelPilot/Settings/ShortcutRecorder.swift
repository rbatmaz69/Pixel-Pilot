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
            .onTapGesture { onChange(nil) }
        }
      }
      .frame(minWidth: 110)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background {
        MorphingRoundedRectangle(cornerRadius: isRecording ? 14 : 7)
          .fill(isRecording ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary))
      }
      .overlay {
        MorphingRoundedRectangle(cornerRadius: isRecording ? 14 : 7)
          .stroke(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
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
