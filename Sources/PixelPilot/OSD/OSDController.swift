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

  /// True while the pointer is inside the HUD.
  ///
  /// The one thing that stops the countdown. Everything else about the HUD is
  /// fire-and-forget; this is the case where the person is plainly still
  /// dealing with it, and taking it away mid-drag would be the interface
  /// walking off in the middle of a sentence.
  private var isHeld = false

  /// Everything the current HUD is made of.
  ///
  /// Kept because the pointer arriving has to redraw it, and the pointer is not
  /// a value anyone passed in. Without this, holding the HUD open would mean
  /// holding a stale copy of it open.
  private struct Presentation {
    let kind: OSDKind
    let value: Double
    let accent: Color
    let displayName: String
    let detail: String?
    let adjust: ((Double) -> Void)?
    let commit: (() -> Void)?
  }

  private var current: Presentation?

  /// - Parameters:
  ///   - adjust: What a drag on the HUD's track means, or nil for a HUD with
  ///     nothing to drag. The controller stays ignorant of displays and audio
  ///     routes: whoever asked for the indicator already knows which of those
  ///     this one is about.
  ///   - commit: Called once when that drag ends — the verified write, kept out
  ///     of the drag for the same reason `ExpressiveSlider` keeps it out.
  func show(
    kind: OSDKind,
    value: Double,
    accent: Color,
    displayName: String,
    on displayID: CGDirectDisplayID,
    detail: String? = nil,
    adjust: ((Double) -> Void)? = nil,
    commit: (() -> Void)? = nil
  ) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
      ?? NSScreen.main
    else { return }

    let isMoving = panel == nil || currentDisplayID != displayID
    if isMoving {
      // Moving to a different display: rebuild rather than reposition, so the
      // entrance animation plays on the screen the user is actually looking at.
      // Before the new presentation is recorded, because tearing down clears it.
      teardown()
    }

    current = Presentation(
      kind: kind,
      value: value,
      accent: accent,
      displayName: displayName,
      detail: detail,
      adjust: adjust,
      commit: commit
    )

    if isMoving {
      makePanel(content: content(), on: screen)
      currentDisplayID = displayID
    } else {
      // Swapping the root view rather than rebuilding preserves SwiftUI's view
      // identity, and with it the HUD's `@State`. That is load-bearing: it is
      // what stops the entrance animation from replaying on every repeat of a
      // held-down key.
      hostingView?.rootView = content()
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
    isHeld = false
    fadeOutAndTeardown()
  }

  /// Holds the HUD open while the pointer is in it, and restarts the countdown
  /// when it leaves.
  ///
  /// Entering during the fade brings it back rather than letting it go: at that
  /// point the pointer is unambiguously on its way to the control, and a HUD
  /// that vanished from under it would have to be summoned again with a key.
  private func setHeld(_ held: Bool) {
    guard isHeld != held, current != nil else { return }
    isHeld = held

    guard held else {
      scheduleDismiss()
      return
    }
    dismissTask?.cancel()
    dismissTask = nil

    guard let panel, panel.alphaValue < 1 else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeInDuration
      panel.animator().alphaValue = 1
    }
  }

  /// The HUD as it currently stands.
  private func content() -> AnyView {
    guard let current else { return AnyView(EmptyView()) }
    return AnyView(
      OSDView(
        kind: current.kind,
        value: current.value,
        accent: current.accent,
        displayName: current.displayName,
        detail: current.detail,
        adjust: current.adjust,
        commit: current.commit
      )
      .withMotionTokens()
      .withAppTheme(paintsWindow: false)
    )
  }

  // MARK: - Panel lifecycle

  private func makePanel(content: AnyView, on screen: NSScreen) {
    // The one panel in the app that takes mouse events. `OverlayPanel` sets out
    // what that costs and why this is the only overlay small enough to be worth
    // it.
    let made = OverlayPanel.make(content: content, acceptsMouse: true)
    self.panel = made.panel
    self.hostingView = made.hosting

    // Hover comes from AppKit rather than from SwiftUI, because this app is
    // never the active one — `OverlayPanel.InteractiveHostingView` explains
    // what that costs `.onHover`.
    (made.hosting as? OverlayPanel.InteractiveHostingView<AnyView>)?
      .onHoverChanged = { [weak self] isInside in self?.setHeld(isInside) }
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
        // Only tear down if nothing asked for the HUD again mid-fade — and the
        // pointer arriving in it counts as asking.
        guard let self, self.dismissTask == nil, !self.isHeld else { return }
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
    current = nil
    isHeld = false
  }

  deinit {
    dismissTask?.cancel()
  }
}
