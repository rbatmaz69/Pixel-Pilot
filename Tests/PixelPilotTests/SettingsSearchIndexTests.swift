import CoreGraphics
import Foundation
import PixelPilotCore
import Testing

@testable import PixelPilot

/// A throwaway defaults suite, so tests never touch the real preferences.
private func makeDefaults() -> UserDefaults {
  let name = "dev.rb.pixelpilot.searchtests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

private final class StubDiscovery: DisplayDiscovering, @unchecked Sendable {
  private let displays: [DiscoveredDisplay]
  init(displays: [DiscoveredDisplay]) { self.displays = displays }
  func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay] { displays }
}

@MainActor
private func makeModel(displays: [DiscoveredDisplay] = []) -> AppModel {
  let model = AppModel(
    discovery: StubDiscovery(displays: displays),
    gamma: GammaDimmer(),
    preferences: Preferences(defaults: makeDefaults()),
    presets: PresetStore(defaults: makeDefaults()),
    keyBindings: KeyBindingStore(defaults: makeDefaults()),
    appRules: AppRuleStore(defaults: makeDefaults())
  )
  model.refresh()
  return model
}

/// The index is hand-written, which is a decision with a known cost: a card
/// renamed in its own file and not here. Nothing can assert the wording still
/// matches. These are the structural half — the parts a test *can* hold.
@Suite("Settings search index")
@MainActor
struct SettingsSearchIndexTests {
  @Test("Every page in the sidebar has something to find")
  func everyPageIsRepresented() {
    let entries = SettingsSearchIndex.entries(model: makeModel())
    for page in AppPage.allCases {
      let found = entries.contains { $0.target == .app(page) }
      #expect(found, "no search entry leads to \(page.title)")
    }
  }

  @Test("The sidebar's two lists between them are every page")
  func appSectionAndOverviewCoverEverything() {
    #expect(Set(AppPage.appSection + [.overview]) == Set(AppPage.allCases))
    #expect(!AppPage.appSection.contains(.overview))
  }

  /// A result with no title is a blank row, and one with no context is a word
  /// with no idea where it came from.
  @Test("Every entry is fully filled in")
  func entriesAreComplete() {
    let entries = SettingsSearchIndex.entries(model: makeModel())
    for entry in entries {
      #expect(!entry.id.isEmpty)
      #expect(!entry.title.isEmpty, "\(entry.id) has no title")
      #expect(!entry.context.isEmpty, "\(entry.id) has no context")
    }
  }

  /// `ForEach` is driven by these. Two entries sharing an id would silently
  /// drop one of them from the results.
  @Test("Ids are unique")
  func idsAreUnique() {
    let entries = SettingsSearchIndex.entries(model: makeModel(displays: [
      DiscoveredDisplay(displayID: 1, key: DisplayKey(rawValue: "aaa"), name: "One", isBuiltin: false),
      DiscoveredDisplay(displayID: 2, key: DisplayKey(rawValue: "bbb"), name: "Two", isBuiltin: false),
    ]))
    #expect(Set(entries.map(\.id)).count == entries.count)
  }

  @Test("Every display target points at a display that exists")
  func displayTargetsAreLive() {
    let model = makeModel(displays: [
      DiscoveredDisplay(displayID: 1, key: DisplayKey(rawValue: "aaa"), name: "One", isBuiltin: false),
    ])
    let live = Set(model.displays.map(\.id))

    for entry in SettingsSearchIndex.entries(model: model) {
      if case let .display(id) = entry.target {
        #expect(live.contains(id))
      }
    }
  }

  @Test("A display contributes one entry per card on its page")
  func everyDisplayGetsItsCards() {
    let model = makeModel(displays: [
      DiscoveredDisplay(displayID: 1, key: DisplayKey(rawValue: "aaa"), name: "One", isBuiltin: false),
      DiscoveredDisplay(displayID: 2, key: DisplayKey(rawValue: "bbb"), name: "Two", isBuiltin: false),
    ])
    let entries = SettingsSearchIndex.entries(model: model)

    for display in model.displays {
      let mine = entries.filter { $0.target == .display(display.id) }
      #expect(mine.count == 7, "\(display.name) has \(mine.count) cards indexed")
      #expect(mine.allSatisfy { $0.context == display.name })
    }
  }

  /// The app writes British and half the people typing at it will not. Every
  /// title carrying one of these spellings has to carry the other as a keyword,
  /// or the card is unfindable to them.
  @Test("British titles are findable by their American spelling")
  func spellingPairsAreCovered() {
    let pairs = [("colour", "color"), ("behaviour", "behavior"),
                 ("grey", "gray"), ("minimise", "minimize")]
    let entries = SettingsSearchIndex.entries(model: makeModel(displays: [
      DiscoveredDisplay(displayID: 1, key: DisplayKey(rawValue: "aaa"), name: "One", isBuiltin: false),
    ]))

    for entry in entries {
      let title = entry.title.lowercased()
      for (british, american) in pairs where title.contains(british) {
        #expect(
          entry.keywords.contains { $0.lowercased().contains(american) },
          "“\(entry.title)” cannot be found by typing “\(american)”"
        )
      }
    }
  }

  /// The one assertion that checks the index and the algorithm agree, rather
  /// than each being fine on its own.
  @Test("Typing what you want finds it first")
  func realQueriesLandCorrectly() {
    let model = makeModel(displays: [
      DiscoveredDisplay(displayID: 1, key: DisplayKey(rawValue: "aaa"), name: "U2720Q", isBuiltin: false),
    ])
    let entries = SettingsSearchIndex.entries(model: model)

    let permissions = SettingsSearch.rank("permissions", in: entries)
    #expect(permissions.first?.title == "Permissions")
    #expect(permissions.first?.target == .app(.keys))

    // The American spelling, end to end.
    #expect(SettingsSearch.rank("color", in: entries).contains { $0.title == "Colour theme" })

    // A display by name reaches that display's cards and nothing else.
    let byName = SettingsSearch.rank("u2720", in: entries)
    #expect(!byName.isEmpty)
    #expect(byName.allSatisfy { $0.target == .display(model.displays[0].id) })
  }

  @Test("A preset the user named is findable by that name")
  func userPresetsAreIndexed() {
    let model = makeModel()
    _ = model.captureCurrentState(name: "Midnight", symbolName: "moon")

    let entries = SettingsSearchIndex.entries(model: model)
    let results = SettingsSearch.rank("midnight", in: entries)

    #expect(results.first?.title == "Midnight")
    #expect(results.first?.target == .app(.presets))
  }
}
