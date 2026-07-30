import Foundation
import Testing

@testable import PixelPilotCore

/// A thread-safe counter, since the debounced call lands on an arbitrary
/// executor.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0

  var count: Int { lock.withLock { _count } }
  func increment() { lock.withLock { _count += 1 } }
}

@Suite("Debouncer")
struct DebouncerTests {
  /// The case it exists for: plugging in one monitor emits several
  /// screen-parameter notifications, and acting on each means rediscovering
  /// displays and re-probing DDC several times over.
  @Test("A burst of triggers produces one call")
  func collapsesBurst() async throws {
    let counter = Counter()
    let debouncer = Debouncer(delay: .milliseconds(60))

    for _ in 0 ..< 10 {
      await debouncer.trigger { counter.increment() }
      try await Task.sleep(for: .milliseconds(5))
    }
    await debouncer.drain()

    #expect(counter.count == 1)
  }

  /// Trailing, not leading. Firing on the first notification would read a
  /// display graph that is still changing.
  @Test("The call happens after the burst, not at its start")
  func firesTrailing() async throws {
    let counter = Counter()
    let debouncer = Debouncer(delay: .milliseconds(80))

    await debouncer.trigger { counter.increment() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(counter.count == 0, "must not fire while triggers are still arriving")

    await debouncer.drain()
    #expect(counter.count == 1)
  }

  @Test("Triggers far apart each get their own call")
  func separatedTriggersBothFire() async throws {
    let counter = Counter()
    let debouncer = Debouncer(delay: .milliseconds(40))

    await debouncer.trigger { counter.increment() }
    await debouncer.drain()

    await debouncer.trigger { counter.increment() }
    await debouncer.drain()

    #expect(counter.count == 2)
  }

  @Test("Cancelling drops the pending call")
  func cancelPreventsCall() async throws {
    let counter = Counter()
    let debouncer = Debouncer(delay: .milliseconds(40))

    await debouncer.trigger { counter.increment() }
    await debouncer.cancel()
    try await Task.sleep(for: .milliseconds(100))

    #expect(counter.count == 0)
    #expect(await debouncer.isPending == false)
  }

  /// Nothing may remain scheduled afterwards — an idle app must be idle.
  @Test("Nothing stays scheduled after firing")
  func settlesToIdle() async throws {
    let counter = Counter()
    let debouncer = Debouncer(delay: .milliseconds(30))

    await debouncer.trigger { counter.increment() }
    await debouncer.drain()
    #expect(await debouncer.isPending == false)

    try await Task.sleep(for: .milliseconds(80))
    #expect(counter.count == 1, "nothing may fire on its own afterwards")
  }

  /// The newest trigger wins: a later reconfiguration describes a later state.
  @Test("The last action of a burst is the one that runs")
  func lastActionWins() async throws {
    let debouncer = Debouncer(delay: .milliseconds(50))
    let observed = Counter()

    await debouncer.trigger { }
    await debouncer.trigger { }
    await debouncer.trigger { observed.increment() }
    await debouncer.drain()

    #expect(observed.count == 1)
  }
}
