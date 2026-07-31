import Foundation
import Testing

@testable import PixelPilotCore

@Suite("App rules")
struct AppRuleTests {
  private func makeStore() -> AppRuleStore {
    let name = "dev.rb.pixelpilot.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return AppRuleStore(defaults: defaults)
  }

  private let presetA = UUID()
  private let presetB = UUID()

  @Test("A rule is found by bundle identifier")
  func lookup() {
    let store = makeStore()
    store.save(AppRule(bundleIdentifier: "com.apple.FinalCut", name: "Final Cut Pro", presetID: presetA))

    #expect(store.rule(forBundleIdentifier: "com.apple.FinalCut")?.presetID == presetA)
    #expect(store.rule(forBundleIdentifier: "com.apple.Safari") == nil)
  }

  /// Two rules for one app would make the winner depend on insertion order,
  /// which is invisible and therefore unfixable by whoever hits it.
  @Test("Saving a second rule for the same app replaces the first")
  func oneRulePerApp() {
    let store = makeStore()
    store.save(AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA))
    store.save(AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetB))

    #expect(store.rules.count == 1)
    #expect(store.rule(forBundleIdentifier: "com.apple.Safari")?.presetID == presetB)
  }

  @Test("Editing a rule in place keeps it as one rule")
  func editingKeepsIdentity() {
    let store = makeStore()
    var rule = AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA)
    store.save(rule)

    rule.presetID = presetB
    store.save(rule)

    #expect(store.rules.count == 1)
    #expect(store.rules.first?.id == rule.id)
    #expect(store.rules.first?.presetID == presetB)
  }

  @Test("Rules and the fallback survive a relaunch")
  func roundTrip() {
    let name = "dev.rb.pixelpilot.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)

    let first = AppRuleStore(defaults: defaults)
    first.save(AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA))
    first.fallbackPresetID = presetB

    let second = AppRuleStore(defaults: defaults)
    #expect(second.rule(forBundleIdentifier: "com.apple.Safari")?.presetID == presetA)
    #expect(second.fallbackPresetID == presetB)
  }

  @Test("Deleting removes only the one asked for")
  func delete() {
    let store = makeStore()
    let rule = AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA)
    store.save(rule)
    store.save(AppRule(bundleIdentifier: "com.apple.Mail", name: "Mail", presetID: presetB))

    store.delete(id: rule.id)

    #expect(store.rules.map(\.bundleIdentifier) == ["com.apple.Mail"])
  }

  /// A rule aimed at a deleted preset does nothing, and does it silently. That
  /// is the worst kind of broken: the rule is still listed, still looks right,
  /// and never fires.
  @Test("Rules pointing at deleted presets are pruned")
  func pruning() {
    let store = makeStore()
    store.save(AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA))
    store.save(AppRule(bundleIdentifier: "com.apple.Mail", name: "Mail", presetID: presetB))

    store.pruneMissingPresets(existing: [presetA])

    #expect(store.rules.map(\.bundleIdentifier) == ["com.apple.Safari"])
  }

  @Test("A deleted fallback preset is cleared too")
  func pruningClearsFallback() {
    let store = makeStore()
    store.fallbackPresetID = presetB

    store.pruneMissingPresets(existing: [presetA])

    #expect(store.fallbackPresetID == nil)
  }

  @Test("Pruning nothing writes nothing")
  func pruningIsANoOpWhenNothingIsMissing() {
    let store = makeStore()
    store.save(AppRule(bundleIdentifier: "com.apple.Safari", name: "Safari", presetID: presetA))
    store.fallbackPresetID = presetA

    store.pruneMissingPresets(existing: [presetA])

    #expect(store.rules.count == 1)
    #expect(store.fallbackPresetID == presetA)
  }
}
