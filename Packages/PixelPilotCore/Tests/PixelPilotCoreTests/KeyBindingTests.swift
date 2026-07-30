import Foundation
import Testing

@testable import PixelPilotCore

@Suite("Key bindability")
struct KeyBindabilityTests {
  /// The rule that matters most. A key read at the HID layer is not consumed,
  /// so binding a letter would move the brightness every time it was typed.
  @Test("Letters and digits are refused")
  func rejectsTypingKeys() {
    for usage: UInt32 in [0x04, 0x10, 0x1D, 0x27] {
      let verdict = KeyBindingRules.bindability(page: HIDPage.keyboard, usage: usage)
      #expect(!verdict.isAllowed, "usage \(usage) should be refused")
    }
  }

  /// A modifier binding would fire on every shortcut in the system.
  @Test("Modifiers are refused")
  func rejectsModifiers() {
    for usage: UInt32 in [0xE0, 0xE3, 0xE7] {
      #expect(!KeyBindingRules.bindability(page: HIDPage.keyboard, usage: usage).isAllowed)
    }
  }

  /// F14 and F15 are what PC keyboards use for brightness, so they must be
  /// bindable — with the caveat that they still reach the foreground app.
  @Test("Function keys are allowed but warned about")
  func warnsAboutFunctionKeys() {
    let verdict = KeyBindingRules.bindability(page: HIDPage.keyboard, usage: 0x69)
    #expect(verdict.isAllowed)
    guard case .allowedWithWarning = verdict else {
      Issue.record("expected a warning for a regular key, got \(verdict)")
      return
    }
  }

  @Test("Consumer media keys are allowed without fuss")
  func allowsConsumerKeys() {
    #expect(KeyBindingRules.bindability(page: HIDPage.consumer, usage: 0x6F) == .allowed)
    #expect(KeyBindingRules.bindability(page: HIDPage.consumer, usage: 0xE9) == .allowed)
  }

  /// The case this whole feature exists for: a keyboard using its own page.
  @Test("Vendor pages are allowed")
  func allowsVendorPages() {
    #expect(KeyBindingRules.bindability(page: 0xFF60, usage: 0x01) == .allowed)
    #expect(KeyBindingRules.bindability(page: 0xFF00, usage: 0x20) == .allowed)
  }

  @Test("Keyboard-page keys outside the typing range are still bindable")
  func allowsNonTypingKeyboardKeys() {
    // 0x3A is F1 — awkward, but the user's call.
    #expect(KeyBindingRules.bindability(page: HIDPage.keyboard, usage: 0x3A).isAllowed)
  }
}

@Suite("Key binding store")
struct KeyBindingStoreTests {
  private func makeStore() -> (KeyBindingStore, UserDefaults) {
    let name = "dev.rb.pixelpilot.keys.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (KeyBindingStore(defaults: defaults), defaults)
  }

  private func signature(
    usage: UInt32, page: UInt32 = HIDPage.consumer, vendor: Int = 1, product: Int = 2
  ) -> KeySignature {
    KeySignature(usagePage: page, usage: usage, vendorID: vendor, productID: product)
  }

  @Test("A taught key round-trips through storage")
  func roundTrip() {
    let (store, defaults) = makeStore()
    store.bind(signature(usage: 0x6F), to: .brightnessUp, keyboardName: "Flow2")

    let restored = KeyBindingStore(defaults: defaults)
    #expect(restored.action(for: signature(usage: 0x6F)) == .brightnessUp)
    #expect(restored.bindings.first?.keyboardName == "Flow2")
  }

  /// The same code on a different keyboard is a different key. Otherwise
  /// teaching one keyboard would silently reprogram another.
  @Test("Keyboards do not share bindings")
  func keyboardsAreIndependent() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F, vendor: 1, product: 2), to: .brightnessUp, keyboardName: "A")

    #expect(store.action(for: signature(usage: 0x6F, vendor: 1, product: 2)) == .brightnessUp)
    #expect(store.action(for: signature(usage: 0x6F, vendor: 9, product: 9)) == nil)
  }

  /// Teaching a new key for an action should move it, not leave two keys doing
  /// the same thing.
  @Test("Re-teaching an action moves it")
  func reteachingMovesTheAction() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F), to: .brightnessUp, keyboardName: "Flow2")
    store.bind(signature(usage: 0x70), to: .brightnessUp, keyboardName: "Flow2")

    #expect(store.action(for: signature(usage: 0x6F)) == nil)
    #expect(store.action(for: signature(usage: 0x70)) == .brightnessUp)
    #expect(store.bindings.count == 1)
  }

  /// But only on the same keyboard — two keyboards may each have their own
  /// brightness-up key.
  @Test("Re-teaching does not disturb another keyboard")
  func reteachingIsScopedToOneKeyboard() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F, vendor: 1), to: .brightnessUp, keyboardName: "A")
    store.bind(signature(usage: 0x6F, vendor: 2), to: .brightnessUp, keyboardName: "B")

    #expect(store.action(for: signature(usage: 0x6F, vendor: 1)) == .brightnessUp)
    #expect(store.action(for: signature(usage: 0x6F, vendor: 2)) == .brightnessUp)
    #expect(store.bindings.count == 2)
  }

  @Test("Rebinding the same key replaces its action")
  func rebindingSameKey() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F), to: .brightnessUp, keyboardName: "Flow2")
    store.bind(signature(usage: 0x6F), to: .volumeUp, keyboardName: "Flow2")

    #expect(store.action(for: signature(usage: 0x6F)) == .volumeUp)
    #expect(store.bindings.count == 1)
  }

  @Test("Unbinding removes it")
  func unbind() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F), to: .brightnessUp, keyboardName: "Flow2")
    store.unbind(signature(usage: 0x6F))

    #expect(store.bindings.isEmpty)
    #expect(store.action(for: signature(usage: 0x6F)) == nil)
  }

  /// The monitor narrows its matching to these, so a missing entry means a
  /// taught key silently stops working.
  @Test("Watched signatures cover every binding")
  func watchedSignatures() {
    let (store, _) = makeStore()
    store.bind(signature(usage: 0x6F), to: .brightnessUp, keyboardName: "Flow2")
    store.bind(signature(usage: 0x70), to: .brightnessDown, keyboardName: "Flow2")

    #expect(store.watchedSignatures().count == 2)
    #expect(store.watchedSignatures().contains(signature(usage: 0x6F)))
  }
}
