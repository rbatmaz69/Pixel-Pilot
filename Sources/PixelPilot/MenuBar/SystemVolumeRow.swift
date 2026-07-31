import PixelPilotCore
import SwiftUI

/// System output volume, with the device it applies to.
///
/// The device picker is not a convenience bolted on next to the slider — on a
/// Mac whose audio goes to a monitor over DisplayPort, it is the only thing on
/// this row that can accomplish anything. That output's level is fixed in the
/// display, so the slider is inert until the audio goes somewhere else.
struct SystemVolumeRow: View {
  @Bindable var audio: SystemAudioModel

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(spacing: Layout.tight) {
        Button {
          audio.toggleMute()
        } label: {
          Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: audio.isMuted)
            .frame(width: 16)
        }
        .buttonStyle(.soft)
        .disabled(!audio.isControllable)
        .help(audio.isMuted ? "Unmute" : "Mute")

        ExpressiveSlider(
          value: Binding(
            get: { audio.volume },
            set: { audio.setVolume($0) }
          ),
          accent: theme.tone
        )
        .disabled(!audio.isControllable)

        devicePicker
      }

      if let reason = audio.unavailableReason {
        // Spelled out rather than left as a greyed-out slider: the reason is
        // fixable, and the fix is the control right next to it.
        Text(reason)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          // Switching output can make this line appear or vanish while the
          // panel is open; without a transition the whole panel jumps.
          .transition(.blurReplace)
      }
    }
    .animation(motion.spatialDefault, value: audio.unavailableReason)
    .onAppear { audio.refresh() }
  }

  private var devicePicker: some View {
    Menu {
      ForEach(audio.devices) { device in
        Button {
          audio.selectDevice(device)
        } label: {
          // Marking the ones with no volume control, rather than hiding them:
          // a device you cannot turn down is still a device you may want to
          // send audio to.
          if device.isDefault {
            Label(label(for: device), systemImage: "checkmark")
          } else {
            Text(label(for: device))
          }
        }
      }
    } label: {
      Image(systemName: "hifispeaker.and.appletv")
    }
    // The same button as the mute control beside it. The list stays AppKit's —
    // it grows and shrinks as devices come and go, and reimplementing it would
    // cost type-select and keyboard navigation for nothing.
    .menuStyle(.button)
    .buttonStyle(.soft)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(audio.currentDeviceName.map { "Output: \($0)" } ?? "Choose audio output")
  }

  private func label(for device: SystemVolume.OutputDevice) -> String {
    device.hasSettableVolume ? device.name : "\(device.name) — fixed level"
  }
}
