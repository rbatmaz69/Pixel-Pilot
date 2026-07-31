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

  private var fadeInDuration: TimeInterval { OverlayPanel.reduceMotion ? 0 : 0.12 }
  private var fadeOutDuration: TimeInterval { OverlayPanel.reduceMotion ? 0.08 : 0.3 }

  /// - Parameter labels: One per screen, keyed by `CGDirectDisplayID`. Screens
  ///   with no entry still get a panel, so nothing is left unlabelled — an
  ///   identify that skips a screen looks like that screen is broken.
  func show(labels: [CGDirectDisplayID: (number: Int, name: String, accent: Color)]) {
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
