import PixelPilotCore
import SwiftUI

/// The system's audio output, as the menu bar sees it.
///
/// Deliberately separate from `DisplayViewModel`. A monitor's own speakers over
/// DDC belong to that monitor, but the system output volume is one global thing
/// — showing it under each display would be wrong the moment a second monitor
/// is connected, and would imply the two sliders do different things.
@MainActor
@Observable
final class SystemAudioModel {
  private(set) var devices: [SystemVolume.OutputDevice] = []
  private(set) var currentDeviceName: String?
  private(set) var isControllable = false

  var volume: Double = 0
  var isMuted = false

  /// Re-reads the device list and current level.
  ///
  /// Called when the panel opens and when the default device changes — never on
  /// a schedule. Enumerating devices probes several properties on each one,
  /// which is cheap once and pointless repeatedly.
  func refresh() {
    devices = SystemVolume.outputDevices()
    currentDeviceName = devices.first(where: \.isDefault)?.name
    isControllable = SystemVolume.isVolumeSettable()
    volume = SystemVolume.volume() ?? 0
    isMuted = SystemVolume.isMuted() ?? false
  }

  func setVolume(_ value: Double) {
    volume = value
    SystemVolume.setVolume(value)
    // macOS convention: moving the volume off zero un-mutes.
    if isMuted, value > 0 {
      isMuted = false
      SystemVolume.setMuted(false)
    }
  }

  func toggleMute() {
    isMuted.toggle()
    SystemVolume.setMuted(isMuted)
  }

  @discardableResult
  func adjustVolume(by step: Double) -> Double {
    setVolume(min(1, max(0, volume + step)))
    return volume
  }

  func selectDevice(_ device: SystemVolume.OutputDevice) {
    guard SystemVolume.setDefaultOutputDevice(device.id) else { return }
    // The change notification will arrive too, but refreshing here keeps the
    // panel from showing the old device for a frame.
    refresh()
  }

  /// Why the slider cannot do anything, when it cannot.
  var unavailableReason: String? {
    guard !isControllable else { return nil }
    let name = currentDeviceName ?? "The current output device"
    return "\(name) has a fixed output level that macOS cannot change. "
      + "Pick a different output below to get a working slider."
  }
}
