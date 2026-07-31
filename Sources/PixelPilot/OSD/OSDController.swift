import AppKit
import SwiftUI

/// Presents the heads-up display.
///
/// The window is created on first use and torn down again once it fades out.
/// That is not premature tidiness: a borderless panel that stays alive keeps a
/// backing store and a compositing layer around for the entire session, on an
/// app whose whole premise is costing nothing while idle.
@MainActor
final class OSDController {
  /// How long the HUD stays up after the last change, matching the system OSD.
  private let visibleDuration: Duration = .milliseconds(1400)

  private var reduceMotion: Bool { OverlayPanel.reduceMotion }

  private var fadeInDuration: TimeInterval { reduceMotion ? 0 : 0.10 }
  private var fadeOutDuration: TimeInterval { reduceMotion ? 0.08 : 0.22 }

  private var panel: NSPanel?
  private var hostingView: NSHostingView<AnyView>?
  /// Cancelled and replaced on every update, so holding a key down keeps the
  /// HUD up rather than making it flicker.
  private var dismissTask: Task<Void, Never>?

  private var currentDisplayID: CGDirectDisplayID?

  func show(
    kind: OSDKind,
    value: Double,
    accent: Color,
    displayName: String,
    on displayID: CGDirectDisplayID
  ) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
      ?? NSScreen.main
    else { return }

    let content = AnyView(
      OSDView(kind: kind, value: value, accent: accent, displayName: displayName)
        .withMotionTokens()
        .withAppTheme(paintsWindow: false)
    )

    if panel == nil || currentDisplayID != displayID {
      // Moving to a different display: rebuild rather than reposition, so the
      // entrance animation plays on the screen the user is actually looking at.
      teardown()
      makePanel(content: content, on: screen)
      currentDisplayID = displayID
    } else {
      // Swapping the root view rather than rebuilding preserves SwiftUI's view
      // identity, and with it the HUD's `@State`. That is load-bearing: it is
      // what stops the entrance animation from replaying on every repeat of a
      // held-down key.
      hostingView?.rootView = content
    }

    guard let panel else { return }
    position(panel, on: screen)

    if panel.alphaValue < 1 {
      // Short, and shorter than the SwiftUI spring inside: the window fade is
      // only there to cover the first frame of compositing. Letting it run as
      // long as the entrance makes the two curves fight and the HUD look soft.
      OverlayPanel.fadeIn(panel, duration: fadeInDuration)
    }

    scheduleDismiss()
  }

  func hide() {
    dismissTask?.cancel()
    dismissTask = nil
    fadeOutAndTeardown()
  }

  // MARK: - Panel lifecycle

  private func makePanel(content: AnyView, on screen: NSScreen) {
    let made = OverlayPanel.make(content: content)
    self.panel = made.panel
    self.hostingView = made.hosting
  }

  private func position(_ panel: NSPanel, on screen: NSScreen) {
    OverlayPanel.position(panel, on: screen) { frame, size in
      CGPoint(
        x: frame.midX - size.width / 2,
        // Roughly where the system places its own OSD, so the two never feel
        // like they belong to different machines.
        y: frame.minY + frame.height * 0.12
      )
    }
  }

  /// A one-shot delayed task, cancelled on every new value. Not a timer: once
  /// the HUD is gone, nothing is scheduled.
  private func scheduleDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { [weak self, visibleDuration] in
      try? await Task.sleep(for: visibleDuration)
      guard !Task.isCancelled else { return }
      self?.dismissTask = nil
      self?.fadeOutAndTeardown()
    }
  }

  private func fadeOutAndTeardown() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeOutDuration
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // Only tear down if nothing asked for the HUD again mid-fade.
        guard let self, self.dismissTask == nil else { return }
        self.teardown()
      }
    }
  }

  private func teardown() {
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
    hostingView = nil
    currentDisplayID = nil
  }

  deinit {
    dismissTask?.cancel()
  }
}
