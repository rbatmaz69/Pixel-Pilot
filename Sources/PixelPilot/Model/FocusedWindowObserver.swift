import AppKit
import ApplicationServices

/// Reports when the focused window changes *within* the frontmost application.
///
/// `NSWorkspace.didActivateApplicationNotification` covers moving between
/// applications and is already observed in `AppModel`. It does not fire for two
/// windows of the same application, which on a desk with two monitors is the
/// ordinary case — two Finder windows, two browser windows, an editor and its
/// terminal. Without this the feature would look broken exactly where people
/// use it most.
///
/// Accessibility is the only way to ask, and the app already holds that
/// permission for the event tap, so nothing new is asked of anyone. If the
/// permission is absent this simply never fires and the app falls back to
/// application-level granularity — degraded, not broken.
///
/// **One application at a time.** The observer is registered on the frontmost
/// process and re-registered when that changes. Observing every running
/// application would mean an `AXObserver` and a run-loop source per process,
/// most of them for applications nobody is looking at.
@MainActor
final class FocusedWindowObserver {
  /// Called when the focused or main window of the frontmost app changed.
  /// Carries nothing: the answer is asked for fresh, because by the time this
  /// arrives the window may have moved again.
  var onChange: (() -> Void)?

  private var observer: AXObserver?
  private var element: AXUIElement?
  private var observedPID: pid_t?

  /// Points at `pid`, dropping whatever was being watched before.
  ///
  /// Safe to call with the same pid repeatedly — a re-activation of the app
  /// that is already frontmost is common (coming back from a dialog) and must
  /// not churn the observer.
  ///
  /// - Returns: Whether a registration is now in place. False means this app
  ///   refused the notification or the permission is missing, and the caller
  ///   falls back to application-level granularity — which is worth knowing
  ///   rather than guessing at.
  @discardableResult
  func follow(pid: pid_t?) -> Bool {
    guard pid != observedPID else { return observer != nil }
    stop()
    guard let pid else { return false }

    var made: AXObserver?
    // The callback is a C function pointer, so it cannot capture. `refcon`
    // carries the observer across, unretained — this object owns the
    // `AXObserver` and tears it down in `stop()`, so the callback cannot
    // outlive it.
    let result = AXObserverCreate(pid, { _, _, _, refcon in
      guard let refcon else { return }
      let observer = Unmanaged<FocusedWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated { observer.onChange?() }
    }, &made)

    guard result == .success, let made else { return false }

    let application = AXUIElementCreateApplication(pid)
    let context = Unmanaged.passUnretained(self).toOpaque()

    // Both, because they answer different questions and applications disagree
    // about which they send. Focus is the precise one; main is what an app
    // reports when its focus is on something that is not a window.
    var registered = false
    for notification in [
      kAXFocusedWindowChangedNotification,
      kAXMainWindowChangedNotification,
    ] as [String] {
      if AXObserverAddNotification(made, application, notification as CFString, context) == .success {
        registered = true
      }
    }

    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode
    )

    observer = made
    element = application
    observedPID = pid
    return registered
  }

  func stop() {
    if let observer {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
      )
      if let element {
        for notification in [
          kAXFocusedWindowChangedNotification,
          kAXMainWindowChangedNotification,
        ] as [String] {
          AXObserverRemoveNotification(observer, element, notification as CFString)
        }
      }
    }
    observer = nil
    element = nil
    observedPID = nil
  }

  /// `isolated`, like `HotkeyCenter`'s, because the state it tears down is
  /// main-actor state. The run loop retains the source, which retains the
  /// observer, which holds an unretained pointer back here — so leaving this to
  /// ARC would leave a callback pointing at freed memory rather than merely
  /// leaking.
  isolated deinit {
    stop()
  }
}
