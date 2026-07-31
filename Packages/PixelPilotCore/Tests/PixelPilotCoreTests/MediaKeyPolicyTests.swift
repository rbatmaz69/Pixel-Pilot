import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Media key policy")
struct MediaKeyPolicyTests {
  // MARK: - External displays

  /// The ordinary case, and the one the app exists for: macOS knows nothing
  /// about a DDC panel, so nothing is competing for the press.
  @Test("An external display takes the key")
  func externalDisplayHandled() {
    #expect(MediaKeyPolicy.handlesBrightness(
      isBuiltin: false, respondsToMediaKeys: true,
      strategy: .ddc, canTakeOverFromSystem: true
    ))
  }

  /// A monitor that refused the capability probe is dimmed through gamma, and
  /// its keys have always worked. Tightening the built-in rules must not reach
  /// it — that would break every display on a dock.
  @Test("An external display on gamma still takes the key, tap or no tap")
  func externalGammaHandledWithoutTap() {
    #expect(MediaKeyPolicy.handlesBrightness(
      isBuiltin: false, respondsToMediaKeys: true,
      strategy: .gamma, canTakeOverFromSystem: false
    ))
  }

  /// The per-display switch is the only way to opt one screen out, so it has to
  /// win over everything else.
  @Test("The per-display switch declines the key")
  func perDisplaySwitchDeclines() {
    #expect(!MediaKeyPolicy.handlesBrightness(
      isBuiltin: false, respondsToMediaKeys: false,
      strategy: .ddc, canTakeOverFromSystem: true
    ))
  }

  // MARK: - The built-in panel

  /// The new behaviour: with the tap installed and DisplayServices available,
  /// the built-in panel is the app's.
  @Test("The built-in panel takes the key on the native path")
  func builtinNativeHandled() {
    #expect(MediaKeyPolicy.handlesBrightness(
      isBuiltin: true, respondsToMediaKeys: true,
      strategy: .native, canTakeOverFromSystem: true
    ))
  }

  /// Without the tap the app can see the press but not stop macOS acting on it,
  /// so acting too would dim the same backlight twice per press. This is the
  /// state a revoked Accessibility grant leaves the app in while the HID monitor
  /// keeps running.
  @Test("The built-in panel declines the key when macOS cannot be stopped")
  func builtinDeclinedWithoutTap() {
    #expect(!MediaKeyPolicy.handlesBrightness(
      isBuiltin: true, respondsToMediaKeys: true,
      strategy: .native, canTakeOverFromSystem: false
    ))
  }

  /// Gamma on the built-in panel would lay a grey film over a backlight still
  /// running at full — dimmer in screenshots, not dimmer in the room.
  @Test("The built-in panel declines the key on gamma")
  func builtinGammaDeclined() {
    #expect(!MediaKeyPolicy.handlesBrightness(
      isBuiltin: true, respondsToMediaKeys: true,
      strategy: .gamma, canTakeOverFromSystem: true
    ))
  }

  /// The built-in panel is never given a transport, so an explicit `.ddc`
  /// override writes into a nil queue: the key would be swallowed and nothing
  /// would move.
  @Test("The built-in panel declines the key on a DDC override")
  func builtinDDCDeclined() {
    #expect(!MediaKeyPolicy.handlesBrightness(
      isBuiltin: true, respondsToMediaKeys: true,
      strategy: .ddc, canTakeOverFromSystem: true
    ))
  }

  /// Switching the built-in panel's own key toggle off is how the ambient-light
  /// behaviour is handed back to macOS without switching the keys off entirely.
  @Test("The built-in panel obeys its own switch")
  func builtinSwitchDeclines() {
    #expect(!MediaKeyPolicy.handlesBrightness(
      isBuiltin: true, respondsToMediaKeys: false,
      strategy: .native, canTakeOverFromSystem: true
    ))
  }

  // MARK: - System volume

  @Test("System volume is taken when the tap is running")
  func systemVolumeHandled() {
    #expect(MediaKeyPolicy.handlesSystemVolume(
      isControllable: true, canTakeOverFromSystem: true
    ))
  }

  /// The same doubling as brightness, and it was already reachable before the
  /// takeover: an external display with no DDC audio and no tap.
  @Test("System volume is declined when macOS cannot be stopped")
  func systemVolumeDeclinedWithoutTap() {
    #expect(!MediaKeyPolicy.handlesSystemVolume(
      isControllable: false, canTakeOverFromSystem: true
    ))
    #expect(!MediaKeyPolicy.handlesSystemVolume(
      isControllable: true, canTakeOverFromSystem: false
    ))
  }
}
