import CoreGraphics
import Testing

@testable import PixelPilotCore

@Suite("Key target")
struct KeyTargetPolicyTests {
  private let builtin: CGDirectDisplayID = 1
  private let external: CGDirectDisplayID = 2
  private let second: CGDirectDisplayID = 3

  private var all: [CGDirectDisplayID] { [builtin, external, second] }
  private func isBuiltin(_ id: CGDirectDisplayID) -> Bool { id == builtin }

  private func target(
    _ mode: KeyTarget,
    focusedWindow: CGDirectDisplayID? = nil,
    pointer: CGDirectDisplayID? = nil,
    connected: [CGDirectDisplayID]? = nil
  ) -> CGDirectDisplayID? {
    KeyTargetPolicy.target(
      mode: mode,
      focusedWindow: focusedWindow,
      pointer: pointer,
      connected: connected ?? all,
      isBuiltin: isBuiltin
    )
  }

  /// The whole point of the change: the pointer is parked on the built-in
  /// panel while the work is happening on the monitor.
  @Test("The focused window wins over a pointer left somewhere else")
  func focusedWindowBeatsAStrandedPointer() {
    #expect(target(.focusedWindow, focusedWindow: external, pointer: builtin) == external)
  }

  @Test("Choosing the pointer keeps the old behaviour exactly")
  func pointerModeIgnoresTheFocusedWindow() {
    #expect(target(.pointer, focusedWindow: external, pointer: builtin) == builtin)
  }

  /// A preference about which signal to believe is not an instruction to give
  /// up when that signal is missing.
  @Test("Each mode falls back to the other signal")
  func eachModeFallsBackToTheOther() {
    #expect(target(.focusedWindow, focusedWindow: nil, pointer: second) == second)
    #expect(target(.pointer, focusedWindow: second, pointer: nil) == second)
  }

  /// A window on a screen the app does not drive — a display it failed to
  /// discover — must not swallow the press.
  @Test("A signal pointing at a display we do not have is passed over")
  func unknownDisplayIsIgnored() {
    #expect(target(.focusedWindow, focusedWindow: 99, pointer: external) == external)
    #expect(target(.focusedWindow, focusedWindow: 99, pointer: 98) == external)
  }

  @Test("With nothing to go on, an external panel is preferred to the built-in one")
  func lastResortPrefersExternal() {
    #expect(target(.focusedWindow) == external)
    #expect(target(.pointer) == external)
  }

  @Test("On a laptop alone, the built-in panel is the answer rather than nothing")
  func builtinOnlyStillAnswers() {
    #expect(target(.focusedWindow, connected: [builtin]) == builtin)
  }

  @Test("With no displays at all there is nothing to aim at")
  func noDisplaysGivesNothing() {
    #expect(target(.focusedWindow, focusedWindow: external, connected: []) == nil)
  }
}
