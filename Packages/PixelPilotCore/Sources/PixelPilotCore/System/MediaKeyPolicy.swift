import Foundation

/// Which media keys the app takes over from macOS, and under what conditions.
///
/// Pure, and outside the app target, for the same reason `BrightnessMapping`
/// is: this is the decision that has been wrong three times — a key consumed
/// that nobody acted on, a release consumed whose press was passed through, a
/// duplicate answered differently from its original — and every one of those
/// was found by pressing a key on a real keyboard rather than by a test. What
/// it costs to get wrong is not a misdrawn slider; it is a Mac whose brightness
/// keys do nothing for as long as this app runs. Here the whole truth table can
/// be written down.
public enum MediaKeyPolicy {
  /// Whether a brightness key press should be acted on.
  ///
  /// - Parameters:
  ///   - isBuiltin: the built-in panel is the one macOS also drives, so it is
  ///     the only one with conditions attached.
  ///   - respondsToMediaKeys: the per-display switch, which is how one screen
  ///     is opted out without switching the keys off everywhere.
  ///   - strategy: the *resolved* strategy — never `.automatic`.
  ///   - canTakeOverFromSystem: whether macOS can be stopped from acting on the
  ///     same press. See `AppModel.canTakeOverFromSystem`.
  public static func handlesBrightness(
    isBuiltin: Bool,
    respondsToMediaKeys: Bool,
    strategy: BrightnessStrategy,
    canTakeOverFromSystem: Bool
  ) -> Bool {
    guard respondsToMediaKeys else { return false }

    // An external panel's backlight is ours alone: macOS has no idea the DDC
    // bus exists, so nothing is competing for the press and no strategy is
    // wrong — gamma on a monitor that refused the capability probe is exactly
    // what that path is for.
    guard isBuiltin else { return true }

    // Everything below is about the built-in panel only.
    //
    // Without the tap macOS is going to dim the same backlight from the same
    // press, so acting as well moves the screen twice per press. Reading the
    // key without being able to swallow it is what the HID monitor does, and it
    // is not enough here.
    guard canTakeOverFromSystem else { return false }

    // And native is the only path that reaches that backlight at all. Gamma
    // would lay a grey film over a backlight still running at full — visible in
    // screenshots, costing contrast, and not what the key is for. DDC does not
    // exist there: the built-in panel is never given a transport, so an explicit
    // `.ddc` override writes into a nil queue and changes nothing while the key
    // is swallowed. Consuming a key and doing nothing visible is the one outcome
    // worse than not handling it.
    return strategy == .native
  }

  /// Whether a volume key aimed at the *system* output should be acted on.
  ///
  /// A display's own speakers need no such test — macOS cannot touch them. The
  /// system output is the opposite case: it is precisely what the key would
  /// have reached anyway, so acting on it without being able to swallow the
  /// press moves the volume two steps.
  public static func handlesSystemVolume(
    isControllable: Bool,
    canTakeOverFromSystem: Bool
  ) -> Bool {
    isControllable && canTakeOverFromSystem
  }
}
