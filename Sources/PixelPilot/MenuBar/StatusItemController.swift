import AppKit
import PixelPilotCore
import SwiftUI

/// The menu bar item: the icon, the click, and the scroll wheel.
///
/// Replaces `MenuBarExtra`, which cannot do either of the last two. A
/// `MenuBarExtra` label is a SwiftUI view the system hosts on its own terms —
/// there is no view of ours in the status item to receive a `scrollWheel(with:)`,
/// and no drawing context in which to build a template image.
@MainActor
final class StatusItemController: NSObject {
  private let model: AppModel
  private let windows: WindowCoordinator

  private var statusItem: NSStatusItem?
  private lazy var panel = MenuBarPanelWindow(onClose: { [weak self] in
    self?.lastAutoDismiss = Date()
    self?.updateHighlight()
  })

  /// Accumulates fractional scroll deltas between applications.
  ///
  /// A trackpad sends dozens of tiny deltas per gesture. Applying each one as
  /// its own brightness change would put a DDC round trip behind every frame of
  /// a swipe; `DDCQueue` coalesces those, but the main-actor work to produce
  /// them is still ours. Accumulating to a step first means one change per
  /// meaningful movement.
  private var scrollAccumulator: Double = 0
  private var scrollMonitor: Any?

  /// When the panel last dismissed itself by losing key status.
  ///
  /// Clicking the status item while the panel is open sends two things in
  /// order: the window resigns key, which closes the panel, and *then* the
  /// button's action fires, which finds no panel and opens a new one. The
  /// panel would flicker and never close on a second click. Every hand-rolled
  /// popover meets this; the fix is to ignore a toggle that arrives on the
  /// heels of a dismissal.
  private var lastAutoDismiss: Date = .distantPast
  private static let reopenGuard: TimeInterval = 0.25

  init(model: AppModel, windows: WindowCoordinator) {
    self.model = model
    self.windows = windows
  }

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = StatusIconRenderer.image(level: nil)
    item.button?.imagePosition = .imageOnly
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    item.button?.toolTip = "Pixel Pilot"
    statusItem = item

    model.onStatusLevelChanged = { [weak self] level in
      self?.statusItem?.button?.image = StatusIconRenderer.image(level: level)
    }

    installScrollHandling(on: item)
  }

  // MARK: - The panel

  @objc private func togglePanel() {
    if panel.isOpen {
      panel.close()
    } else if Date().timeIntervalSince(lastAutoDismiss) < Self.reopenGuard {
      // The panel just closed itself because this very click took key status
      // away from it. Opening again here is what makes a popover impossible to
      // dismiss by clicking its own icon.
      lastAutoDismiss = .distantPast
    } else {
      guard let button = statusItem?.button else { return }
      panel.show(
        anchoredTo: button,
        content: MenuBarPanel(
          model: model,
          onOpenDisplays: { [weak self] in
            self?.panel.close()
            self?.updateHighlight()
            self?.windows.showDisplays()
          },
          onOpenSettings: { [weak self] in
            self?.panel.close()
            self?.updateHighlight()
            self?.windows.showSettings()
          }
        )
      )
    }
    updateHighlight()
  }

  private func updateHighlight() {
    statusItem?.button?.highlight(panel.isOpen)
  }

  // MARK: - Scrolling over the icon

  /// Scrolling anywhere over the icon changes brightness.
  ///
  /// A **local** monitor: the events are already being delivered to this
  /// process's status item window, so nothing has to be intercepted globally
  /// and no permission is involved. It also costs nothing when no scroll
  /// arrives, which a polling approach would not.
  ///
  /// Returning `nil` swallows the event. That is right here — a scroll over a
  /// menu bar icon has no other meaning — but only for events that landed on
  /// *our* window, hence the identity check.
  private func installScrollHandling(on item: NSStatusItem) {
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self, weak item] event in
      guard let self, let button = item?.button, event.window === button.window else {
        return event
      }
      MainActor.assumeIsolated { self.handleScroll(event) }
      return nil
    }
  }

  private func handleScroll(_ event: NSEvent) {
    // A trackpad reports precise deltas in points and a wheel reports notches,
    // and the two are two orders of magnitude apart. One divisor for both would
    // make the wheel useless or the trackpad unusable.
    let raw = event.hasPreciseScrollingDeltas
      ? Double(event.scrollingDeltaY) / 400
      : Double(event.scrollingDeltaY) / 40
    scrollAccumulator += event.isDirectionInvertedFromDevice ? -raw : raw

    let step = model.preferences.global.keyStep
    guard abs(scrollAccumulator) >= step else { return }

    let direction: Double = scrollAccumulator > 0 ? 1 : -1
    scrollAccumulator = 0

    // The display the icon is on, not the one under the pointer — the pointer
    // is over the menu bar, so `focusedDisplay` would give the same answer
    // today, but only by accident of where the menu bar happens to be.
    guard let display = displayUnderStatusItem, display.isReady else { return }
    let value = display.adjustBrightness(by: direction * step)
    model.presentScrolledBrightness(value, on: display)
  }

  private var displayUnderStatusItem: DisplayViewModel? {
    guard let screen = statusItem?.button?.window?.screen, let id = screen.displayID else {
      return model.focusedDisplay
    }
    return model.displays.first { $0.displayID == id } ?? model.focusedDisplay
  }

  /// Removes the item and the monitor.
  ///
  /// There is no `deinit` doing this. This object is installed once at launch
  /// and lives for the process, so a deinit would be code that never runs —
  /// and it cannot touch `scrollMonitor` from a nonisolated context anyway.
  /// The explicit method is here for the one caller that could ever want it,
  /// rather than pretending a cleanup path exists.
  func uninstall() {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    scrollMonitor = nil
    panel.close()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
}
