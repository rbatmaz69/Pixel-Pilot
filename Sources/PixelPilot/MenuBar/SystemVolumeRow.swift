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
  @State private var isDevicePickerOpen = false

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
        .help(audio.isMuted ? "Ton ein" : "Stumm")

        ExpressiveSlider(
          value: Binding(
            get: { audio.volume },
            set: { audio.setVolume($0) }
          ),
          accent: theme.tone
        )
        .disabled(!audio.isControllable)

        devicePickerButton
      }

      if isDevicePickerOpen {
        deviceList
          .transition(.blurReplace.combined(with: .scale(0.98, anchor: .top)))
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
    .animation(motion.tactileSnap ?? motion.spatialDefault, value: isDevicePickerOpen)
    .onAppear { audio.refresh() }
  }

  private var devicePickerButton: some View {
    Button {
      audio.refresh()
      isDevicePickerOpen.toggle()
      Haptics.detent()
    } label: {
      Image(systemName: "hifispeaker.and.appletv")
        .symbolVariant(isDevicePickerOpen ? .fill : .none)
    }
    .buttonStyle(.soft(isDevicePickerOpen ? theme.tone : .secondary))
    .fixedSize()
    .help(audio.currentDeviceName.map { "Audio-Ausgang: \($0)" } ?? "Audio-Ausgang wählen")
    .accessibilityLabel("Audio-Ausgang wählen")
    .accessibilityValue(audio.currentDeviceName ?? "")
  }

  private var deviceList: some View {
    VStack(alignment: .leading, spacing: 4) {
      if audio.devices.isEmpty {
        Text("Keine Audio-Ausgabegeräte gefunden")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
      } else {
        ForEach(audio.devices) { device in
          Button {
            audio.selectDevice(device)
            isDevicePickerOpen = false
            Haptics.confirm()
          } label: {
            HStack(spacing: 7) {
              Image(systemName: device.isDefault ? "checkmark.circle.fill" : "speaker.wave.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(device.isDefault ? theme.tone : .secondary)
                .frame(width: 14)

              Text(device.name)
                .font(TypeScale.detail.weight(device.isDefault ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

              Spacer(minLength: 4)

              if !device.hasSettableVolume {
                Text("Fester Pegel")
                  .font(.system(size: 9.5, weight: .medium))
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
                .fill(device.isDefault ? theme.tone.opacity(theme.isDark ? 0.18 : 0.12) : theme.recessedWell)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
                .strokeBorder(
                  device.isDefault ? theme.tone.opacity(0.45) : theme.groupBorder,
                  lineWidth: 0.75
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.top, 2)
  }
}
