import AppKit
import SwiftUI

/// Puts a big number on every screen at once.
///
/// "Which of these is Display 2" is a question with no good answer from a
/// sidebar, and it is the first question anyone with three monitors has. The
/// system's own Displays settings has had this for years for the same reason.
///
/// A separate controller rather than a mode of `OSDController`, because that
/// one deliberately owns exactly one panel and rebuilds it when the display
/// changes — the opposite of what is needed here. They share the panel
/// configuration through `OverlayPanel`.
@MainActor
final class IdentifyController {
  private let visibleDuration: Duration = .seconds(2)

  private var panels: [NSPanel] = []
  private var dismissTask: Task<Void, Never>?
  private var highlightedDisplayID: CGDirectDisplayID?

  private var fadeInDuration: TimeInterval { OverlayPanel.reduceMotion ? 0 : 0.12 }
  private var fadeOutDuration: TimeInterval { OverlayPanel.reduceMotion ? 0.08 : 0.3 }

  /// - Parameter labels: One per screen, keyed by `CGDirectDisplayID`. Screens
  ///   with no entry still get a panel, so nothing is left unlabelled — an
  ///   identify that skips a screen looks like that screen is broken.
  func show(labels: [CGDirectDisplayID: (number: Int, name: String, accent: Color)]) {
    highlightedDisplayID = nil
    teardown()

    for (index, screen) in NSScreen.screens.enumerated() {
      let id = screen.displayID
      let label = id.flatMap { labels[$0] }
      let content = AnyView(
        IdentifyOverlay(
          number: label?.number ?? index + 1,
          name: label?.name ?? screen.localizedName,
          accent: label?.accent ?? ThemeStore.shared.theme.tone
        )
        .withMotionTokens()
        .withAppTheme(paintsWindow: false)
      )

      let made = OverlayPanel.make(content: content)
      OverlayPanel.position(made.panel, on: screen) { frame, size in
        CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
      }
      OverlayPanel.fadeIn(made.panel, duration: fadeInDuration)
      panels.append(made.panel)
    }

    scheduleDismiss()
  }

  /// Shows a warm glowing border + badge on the single physical screen currently
  /// being arranged in `DisplayMap`, without stealing focus or running timers.
  func showSingleHighlight(displayID: CGDirectDisplayID, name: String, accent: Color) {
    guard highlightedDisplayID != displayID else { return }
    dismissTask?.cancel()
    dismissTask = nil
    teardown()

    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
    highlightedDisplayID = displayID

    let content = AnyView(
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(accent.opacity(0.88), lineWidth: 6)
          .shadow(color: accent.opacity(0.55), radius: 18)
          .padding(8)

        HStack(spacing: 8) {
          AccentDot(accent: accent, isReady: true, size: 8)
          Text(name)
            .font(TypeScale.sheetTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .heroSurface()
        .padding(.top, 28)
      }
      .frame(width: screen.frame.width, height: screen.frame.height)
      .withMotionTokens()
      .withAppTheme(paintsWindow: false)
    )

    let made = OverlayPanel.make(content: content)
    made.panel.setFrame(screen.frame, display: false)
    OverlayPanel.fadeIn(made.panel, duration: fadeInDuration)
    panels.append(made.panel)
  }

  /// Fades out and tears down any live arrange highlight (`0.0% idle CPU`).
  func endHighlight() {
    guard highlightedDisplayID != nil else { return }
    highlightedDisplayID = nil
    dismissTask?.cancel()
    dismissTask = nil
    fadeOutAndTeardown()
  }

  /// One delayed task for all of them, so they leave together. Not a timer:
  /// once the overlays are gone, nothing is scheduled.
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
    let leaving = panels
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeOutDuration
      for panel in leaving { panel.animator().alphaValue = 0 }
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.dismissTask == nil else { return }
        self.teardown()
      }
    }
  }

  private func teardown() {
    for panel in panels {
      panel.orderOut(nil)
      // Same reason as everywhere else in this app: dropping the content view
      // drops the SwiftUI hierarchy rather than leaving it standing.
      panel.contentView = nil
    }
    panels = []
  }

  deinit {
    dismissTask?.cancel()
  }
}
