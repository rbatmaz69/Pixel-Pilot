import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Settings search")
struct SettingsSearchTests {
  /// Stands in for a `SettingsRoute`, which lives in the app. The point of the
  /// generic parameter is that this package does not care what it is.
  private typealias Entry = SearchEntry<String>

  private func entry(
    _ id: String, _ title: String, _ context: String, _ keywords: [String] = []
  ) -> Entry {
    Entry(id: id, title: title, context: context, keywords: keywords, target: id)
  }

  private var fixture: [Entry] {
    [
      entry("theme", "Colour theme", "General", ["color", "accent", "dark", "light"]),
      entry("startup", "Startup", "General", ["login", "launch", "open at login"]),
      entry("permissions", "Permissions", "Keys", ["accessibility", "input monitoring", "grant"]),
      entry("detection", "Key detection", "Keys", ["hid", "teach", "learn"]),
      entry("stops", "Stops", "Schedule", ["sunrise", "sunset", "solar"]),
    ]
  }

  /// A field with no text in it is not a question. Answering it with every card
  /// in the app would replace the sidebar the instant it was focused.
  @Test("An empty query answers with nothing")
  func emptyQueryFindsNothing() {
    #expect(SettingsSearch.rank("", in: fixture).isEmpty)
    #expect(SettingsSearch.rank("   ", in: fixture).isEmpty)
    #expect(SettingsSearch.rank("\t\n", in: fixture).isEmpty)
  }

  @Test("A word of the title beats a keyword beats the page name")
  func titleBeatsKeywordBeatsContext() {
    // "key" is the first word of "Key detection", a page name for two entries,
    // and nobody's keyword.
    let results = SettingsSearch.rank("key", in: fixture)
    #expect(results.first?.id == "detection")
    // Permissions is on the Keys page, so it comes along — behind.
    #expect(results.map(\.id).contains("permissions"))
  }

  @Test("A second word narrows rather than widens")
  func tokensAreAnded() {
    let results = SettingsSearch.rank("key perm", in: fixture)
    #expect(results.map(\.id) == ["permissions"])
  }

  /// The other half of the same decision: the tokens are separate words, so
  /// running them together is not a spelling of the same query.
  @Test("Words run together match nothing")
  func tokensAreNotConcatenated() {
    #expect(SettingsSearch.rank("keyperm", in: fixture).isEmpty)
  }

  @Test("A token that matches nothing drops the entry entirely")
  func oneMissingTokenIsFatal() {
    #expect(SettingsSearch.rank("colour zzzz", in: fixture).isEmpty)
  }

  @Test("Typing is case insensitive")
  func caseIsIgnored() {
    #expect(SettingsSearch.rank("STOPS", in: fixture).map(\.id) == ["stops"])
    #expect(SettingsSearch.rank("sTaRtUp", in: fixture).map(\.id) == ["startup"])
  }

  @Test("Accents fold in both directions")
  func diacriticsFold() {
    let accented = [entry("cafe", "Café", "General", ["coffee"])]
    #expect(SettingsSearch.rank("cafe", in: accented).map(\.id) == ["cafe"])
    #expect(SettingsSearch.rank("café", in: accented).map(\.id) == ["cafe"])
    // And the other way: an accented query against an unaccented title.
    #expect(SettingsSearch.rank("cölour", in: fixture).map(\.id) == ["theme"])
  }

  /// The spelling this app writes and the spelling half its users type are not
  /// the same, and a search that only knows the first has chosen to be right
  /// over useful.
  @Test("The American spelling finds the British title")
  func spellingPairsWork() {
    #expect(SettingsSearch.rank("color", in: fixture).map(\.id) == ["theme"])
    #expect(SettingsSearch.rank("colour", in: fixture).map(\.id) == ["theme"])
  }

  @Test("A word in the middle of a title is found")
  func laterWordsMatch() {
    #expect(SettingsSearch.rank("detection", in: fixture).map(\.id) == ["detection"])
  }

  /// The guarantee the index depends on: it is written in sidebar order, so two
  /// answers that are equally good come back in the order they appear in the
  /// window rather than in whatever order the sort happened to leave them.
  @Test("Equal scores keep declaration order")
  func tiesAreStable() {
    let tied = [
      entry("first", "Alpha", "Page", ["shared"]),
      entry("second", "Alpha", "Page", ["shared"]),
      entry("third", "Alpha", "Page", ["shared"]),
    ]
    #expect(SettingsSearch.rank("alpha", in: tied).map(\.id) == ["first", "second", "third"])
    // And again from a keyword, which takes the other branch of the scorer.
    #expect(SettingsSearch.rank("shared", in: tied).map(\.id) == ["first", "second", "third"])
  }

  @Test("The limit is respected")
  func limitTruncates() {
    let many = (0..<20).map { entry("e\($0)", "Alpha \($0)", "Page") }
    #expect(SettingsSearch.rank("alpha", in: many).count == 8)
    #expect(SettingsSearch.rank("alpha", in: many, limit: 3).count == 3)
  }

  @Test("An exact keyword beats a keyword that merely starts the same way")
  func exactKeywordWins() {
    let pair = [
      entry("prefix", "One", "Page", ["logins"]),
      entry("exact", "Two", "Page", ["login"]),
    ]
    #expect(SettingsSearch.rank("login", in: pair).map(\.id) == ["exact", "prefix"])
  }

  @Test("Nothing at all is a clean empty answer, not a crash")
  func noEntriesIsFine() {
    #expect(SettingsSearch.rank("anything", in: [Entry]()).isEmpty)
  }
}
