import CoreGraphics
import Foundation
import PixelPilotCore
import Testing

@testable import PixelPilot

/// Hands back whatever display set the test asks for.
///
/// Exists because unplugging a monitor by hand is the only other way to reach
/// these paths, and they are the ones that go wrong quietly: a display that
/// comes back with a different `CGDirectDisplayID`, or one that leaves while
/// dimmed.
private final class StubDiscovery: DisplayDiscovering, @unchecked Sendable {
  private let lock = NSLock()
  private var _displays: [DiscoveredDisplay]
  private var _callCount = 0

  init(displays: [DiscoveredDisplay] = []) {
    self._displays = displays
  }

  var callCount: Int { lock.withLock { _callCount } }

  func set(_ displays: [DiscoveredDisplay]) {
    lock.withLock { _displays = displays }
  }

  func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay] {
    lock.withLock {
      _callCount += 1
      return _displays
    }
  }
}

private func makeDisplay(
  id: CGDirectDisplayID, key: String, name: String
) -> DiscoveredDisplay {
  DiscoveredDisplay(
    displayID: id, key: DisplayKey(rawValue: key), name: name, isBuiltin: false
  )
}

/// Preferences on a throwaway suite, so tests never touch the real ones.
private func makePreferences() -> Preferences {
  let name = "dev.rb.pixelpilot.apptests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return Preferences(defaults: defaults)
}

@MainActor
@Suite("App model")
struct AppModelTests {
  @Test("Discovered displays become view models")
  func buildsViewModels() {
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "U32T1"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )

    model.refresh()

    #expect(model.displays.count == 2)
    #expect(model.displays.map(\.name) == ["U32T1", "Second"])
  }

  /// The property that matters when a monitor is replugged: macOS hands out a
  /// different `CGDirectDisplayID`, so identity has to come from the
  /// `DisplayKey` or every setting is lost on reconnect.
  @Test("A display reconnecting under a new ID keeps its identity")
  func survivesReconnectWithNewDisplayID() {
    let discovery = StubDiscovery(displays: [makeDisplay(id: 3, key: "aaa", name: "U32T1")])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()
    let before = model.displays.first?.id

    // Unplugged and plugged back in: same panel, new CoreGraphics id.
    discovery.set([makeDisplay(id: 9, key: "aaa", name: "U32T1")])
    model.refresh()

    #expect(model.displays.first?.id == before)
    #expect(model.displays.first?.displayID == 9)
  }

  @Test("A display that goes away is dropped")
  func dropsDisappearedDisplays() {
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "First"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()

    discovery.set([makeDisplay(id: 1, key: "aaa", name: "First")])
    model.refresh()

    #expect(model.displays.count == 1)
    #expect(model.displays.first?.name == "First")
  }

  /// A monitor unplugged while dimmed would otherwise keep its gamma entry
  /// forever — and have it reasserted onto whatever display inherits its id.
  @Test("Gamma entries for departed displays are cleaned up")
  func prunesGammaOnDisappearance() {
    let gamma = GammaDimmer()
    let discovery = StubDiscovery(displays: [
      makeDisplay(id: 1, key: "aaa", name: "First"),
      makeDisplay(id: 2, key: "bbb", name: "Second"),
    ])
    let model = AppModel(discovery: discovery, gamma: gamma, preferences: makePreferences())
    model.refresh()

    gamma.setDimming(0.5, for: 1)
    gamma.setDimming(0.5, for: 2)
    #expect(gamma.dimmedDisplays.count == 2)

    discovery.set([makeDisplay(id: 1, key: "aaa", name: "First")])
    model.refresh()

    #expect(gamma.dimmedDisplays == [1])
  }

  @Test("No displays is a valid state, not a crash")
  func handlesNoDisplays() {
    let discovery = StubDiscovery(displays: [])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )
    model.refresh()

    #expect(model.displays.isEmpty)
    #expect(model.focusedDisplay == nil)
  }

  @Test("Quitting restores every dimmed display")
  func stopClearsGamma() {
    let gamma = GammaDimmer()
    let model = AppModel(
      discovery: StubDiscovery(), gamma: gamma, preferences: makePreferences()
    )

    gamma.setDimming(0.4, for: 1)
    model.stop()

    #expect(gamma.dimmedDisplays.isEmpty, "a dimmed display left behind looks like broken hardware")
  }

  /// Each refresh must ask again. Caching here would mean a monitor plugged in
  /// after launch never appears.
  @Test("Every refresh re-asks for the display list")
  func refreshAlwaysRediscovers() {
    let discovery = StubDiscovery(displays: [makeDisplay(id: 1, key: "aaa", name: "First")])
    let model = AppModel(
      discovery: discovery, gamma: GammaDimmer(), preferences: makePreferences()
    )

    model.refresh()
    model.refresh()
    model.refresh()

    #expect(discovery.callCount == 3)
  }
}
