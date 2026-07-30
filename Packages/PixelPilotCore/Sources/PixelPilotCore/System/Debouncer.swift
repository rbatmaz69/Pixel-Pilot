import Foundation

/// Collapses a burst of triggers into one trailing call.
///
/// Plugging in a single monitor makes macOS emit several screen-parameter
/// notifications in a row. Acting on each one means rediscovering displays and
/// re-probing DDC several times over, on a bus where every transaction costs
/// tens of milliseconds — so the burst has to become one action.
///
/// Trailing rather than leading: the useful moment is *after* the display graph
/// has settled. Reacting to the first notification reads a half-finished state.
///
/// This is not a timer in the sense the rest of the app avoids. It exists only
/// between a trigger and its delayed call; once fired, nothing is scheduled and
/// the object costs nothing.
public actor Debouncer {
  private let delay: Duration
  private var pending: Task<Void, Never>?

  public init(delay: Duration) {
    self.delay = delay
  }

  deinit {
    pending?.cancel()
  }

  /// Schedules `action`, replacing anything already waiting.
  public func trigger(_ action: @escaping @Sendable () async -> Void) {
    pending?.cancel()
    pending = Task { [delay] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        // Cancelled by a newer trigger; that one owns the call now.
        return
      }
      guard !Task.isCancelled else { return }
      await self.clearPending()
      await action()
    }
  }

  /// Drops a scheduled call without running it.
  public func cancel() {
    pending?.cancel()
    pending = nil
  }

  public var isPending: Bool { pending != nil }

  /// Waits for a scheduled call to finish, for tests and for shutdown.
  public func drain() async {
    await pending?.value
  }

  private func clearPending() {
    pending = nil
  }
}
