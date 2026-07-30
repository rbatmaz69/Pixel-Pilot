// AudioToolbox is needed for kAudioHardwareServiceDeviceProperty_VirtualMainVolume.
// It is the device's aggregate volume, which is what the volume keys move —
// unlike kAudioDevicePropertyVolumeScalar, which many devices only expose
// per-channel and not on the main element.
import AudioToolbox
import CoreAudio
import Foundation
import os

/// System audio output volume, via CoreAudio.
///
/// This is the fallback when a display has no usable DDC audio — which, going by
/// the panel this was developed against, is the common case. Monitors routinely
/// answer volume queries with garbage while having no speakers at all, so
/// treating DDC audio as the primary path would leave a slider that moves and
/// changes nothing.
public enum SystemVolume {
  private static let logger = Logger(subsystem: "dev.rb.pixelpilot", category: "audio")

  public static var defaultOutputDevice: AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  /// Whether the current output device exposes a volume we can move.
  ///
  /// False for fixed digital outputs — DisplayPort and HDMI audio endpoints,
  /// which carry level control in the sink rather than the source. This is not
  /// an edge case: a Mac driving a monitor over DisplayPort routinely lands here.
  public static func isVolumeSettable() -> Bool {
    guard let device = defaultOutputDevice else { return false }
    var address = volumeAddress()
    guard AudioObjectHasProperty(device, &address) else { return false }

    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
    return settable.boolValue
  }

  /// Returns nil when the current output device has no settable volume — a
  /// digital output over DisplayPort or HDMI, for instance.
  public static func volume() -> Double? {
    guard let device = defaultOutputDevice else { return nil }
    var address = volumeAddress()
    guard AudioObjectHasProperty(device, &address) else { return nil }

    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return Double(value)
  }

  @discardableResult
  public static func setVolume(_ fraction: Double) -> Bool {
    guard let device = defaultOutputDevice else { return false }
    var address = volumeAddress()

    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &address),
          AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
          settable.boolValue
    else { return false }

    var value = Float32(min(1.0, max(0.0, fraction)))
    let status = AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
    )
    return status == noErr
  }

  public static func isMuted() -> Bool? {
    guard let device = defaultOutputDevice else { return nil }
    var address = muteAddress()
    guard AudioObjectHasProperty(device, &address) else { return nil }

    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value != 0
  }

  @discardableResult
  public static func setMuted(_ muted: Bool) -> Bool {
    guard let device = defaultOutputDevice else { return false }
    var address = muteAddress()

    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &address),
          AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
          settable.boolValue
    else { return false }

    var value: UInt32 = muted ? 1 : 0
    let status = AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
    )
    return status == noErr
  }
}

/// Drives volume for one display, preferring the monitor's own speakers when
/// they are real and falling back to system output when they are not.
public actor VolumeController {
  public enum Route: Equatable, Sendable {
    /// The monitor's speakers, over DDC.
    case displaySpeakers
    /// The system's default output device.
    case system
    /// Nothing to drive.
    case unavailable

    public var displayName: String {
      switch self {
      case .displaySpeakers: "Display speakers"
      case .system: "System output"
      case .unavailable: "Unavailable"
      }
    }
  }

  private let queue: DDCQueue?
  private let capabilities: DisplayCapabilities?
  private let log: DiagnosticsLog?

  private var ddcMaximum: UInt16 = 100
  private var currentVolume: Double = 0
  private var currentlyMuted = false
  private var hasPrimed = false

  public init(
    queue: DDCQueue?,
    capabilities: DisplayCapabilities?,
    log: DiagnosticsLog? = nil
  ) {
    self.queue = queue
    self.capabilities = capabilities
    self.log = log
  }

  /// DDC audio is used only when the capability probe found it genuinely
  /// usable — a probe that rejects a 0xFFFF maximum, so phantom controls do not
  /// get here.
  ///
  /// The system route requires more than a device existing. A monitor connected
  /// over DisplayPort presents an audio endpoint whose volume is fixed in
  /// hardware; macOS reports no volume for it at all. Treating "a device is
  /// present" as "volume is controllable" would put a dead slider in the UI, so
  /// the property is actually checked.
  public var route: Route {
    if queue != nil, capabilities?.isUsable(.audioSpeakerVolume) == true {
      return .displaySpeakers
    }
    if SystemVolume.isVolumeSettable() {
      return .system
    }
    return .unavailable
  }

  public func volume() -> Double { currentVolume }
  public func isMuted() -> Bool { currentlyMuted }

  public func prime() async {
    guard !hasPrimed else { return }
    hasPrimed = true

    switch route {
    case .displaySpeakers:
      guard let queue else { break }
      if let reading = try? await queue.read(.audioSpeakerVolume), reading.maximum > 0 {
        ddcMaximum = reading.maximum
        currentVolume = Double(reading.current) / Double(reading.maximum)
      }
      if capabilities?.isUsable(.audioMute) == true,
         let mute = try? await queue.read(.audioMute) {
        currentlyMuted = mute.current == 1
      }

    case .system:
      currentVolume = SystemVolume.volume() ?? 0
      currentlyMuted = SystemVolume.isMuted() ?? false

    case .unavailable:
      break
    }

    log?.record(.info("Volume primed at \(Int(currentVolume * 100))% via \(route.displayName)"))
  }

  public func setVolume(_ fraction: Double) async {
    let value = min(1.0, max(0.0, fraction))
    currentVolume = value

    switch route {
    case .displaySpeakers:
      await queue?.set(.audioSpeakerVolume, value: UInt16((value * Double(ddcMaximum)).rounded()))
    case .system:
      SystemVolume.setVolume(value)
    case .unavailable:
      break
    }

    // Matching macOS: moving the volume off zero un-mutes.
    if currentlyMuted, value > 0 {
      await setMuted(false)
    }
  }

  public func setMuted(_ muted: Bool) async {
    currentlyMuted = muted

    switch route {
    case .displaySpeakers:
      guard capabilities?.isUsable(.audioMute) == true else {
        // No real mute control: approximate it by dropping the volume.
        await queue?.set(.audioSpeakerVolume, value: muted ? 0 : UInt16((currentVolume * Double(ddcMaximum)).rounded()))
        return
      }
      // MCCS: 1 mutes, 2 unmutes.
      await queue?.set(.audioMute, value: muted ? 1 : 2)
    case .system:
      SystemVolume.setMuted(muted)
    case .unavailable:
      break
    }
  }

  @discardableResult
  public func adjustVolume(by step: Double) async -> Double {
    await setVolume(currentVolume + step)
    return currentVolume
  }
}
