import CoreGraphics

/// Which display a key press is aimed at.
///
/// Pure and outside the app target, for the reason `MediaKeyPolicy` is: this is
/// a decision made on every press, its inputs come from three different places
/// that can each be absent, and getting it wrong is not a misdrawn control but
/// the wrong screen going dark. Written down here, the fallback chain can be
/// read in one go instead of being inferred from a chain of `??`.
public enum KeyTargetPolicy {
  /// - Parameters:
  ///   - focusedWindow: where the frontmost application's focused window is.
  ///     Absent when nothing could be asked — no Accessibility permission, an
  ///     application that does not expose its windows, or a desktop with only
  ///     the Finder in front.
  ///   - pointer: the screen under the pointer, absent when it is somewhere we
  ///     have no display for.
  ///   - connected: every display the app is currently driving, in the order it
  ///     discovered them.
  ///   - isBuiltin: which of those is the Mac's own panel.
  public static func target(
    mode: KeyTarget,
    focusedWindow: CGDirectDisplayID?,
    pointer: CGDirectDisplayID?,
    connected: [CGDirectDisplayID],
    isBuiltin: (CGDirectDisplayID) -> Bool
  ) -> CGDirectDisplayID? {
    // The chosen answer first, then the other one, then a guess. The two modes
    // share a fallback rather than each having their own: a preference for the
    // focused window is a preference about which signal to *believe*, not an
    // instruction to do nothing when that signal is missing.
    let preferred: [CGDirectDisplayID?] = switch mode {
    case .focusedWindow: [focusedWindow, pointer]
    case .pointer: [pointer, focusedWindow]
    }

    for candidate in preferred {
      if let candidate, connected.contains(candidate) { return candidate }
    }

    // Last resort: an external panel before the built-in one. Someone with a
    // monitor plugged in almost always means the monitor, and the built-in
    // panel is the one macOS would have handled by itself anyway.
    return connected.first(where: { !isBuiltin($0) }) ?? connected.first
  }
}
