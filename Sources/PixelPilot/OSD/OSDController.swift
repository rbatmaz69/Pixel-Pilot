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
  private let fadeDuration: TimeInterval = 0.22

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
    )

    if panel == nil || currentDisplayID != displayID {
      // Moving to a different display: rebuild rather than reposition, so the
      // entrance animation plays on the screen the user is actually looking at.
      teardown()
      makePanel(content: content, on: screen)
      currentDisplayID = displayID
    } else {
      hostingView?.rootView = content
    }

    guard let panel else { return }
    position(panel, on: screen)

    if panel.alphaValue < 1 {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.14
        panel.animator().alphaValue = 1
      }
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
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = [.intrinsicContentSize]

    let panel = NSPanel(
      contentRect: .zero,
      // .nonactivatingPanel is the important one: showing the HUD must never
      // steal focus from whatever the user is working in.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = hosting
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The glass material draws its own shadow; a window shadow on top of it
    // produces a visible double edge.
    panel.hasShadow = false
    panel.isMovable = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .screenSaver
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .stationary,
    ]
    panel.alphaValue = 0

    self.panel = panel
    self.hostingView = hosting
  }

  private func position(_ panel: NSPanel, on screen: NSScreen) {
    panel.layoutIfNeeded()
    let size = panel.contentView?.fittingSize ?? CGSize(width: 200, height: 150)
    panel.setContentSize(size)

    let frame = screen.frame
    let origin = CGPoint(
      x: frame.midX - size.width / 2,
      // Roughly where the system places its own OSD, so the two never feel like
      // they belong to different machines.
      y: frame.minY + frame.height * 0.12
    )
    panel.setFrameOrigin(origin)
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
      context.duration = fadeDuration
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
