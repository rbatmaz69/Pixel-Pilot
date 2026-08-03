import Testing

@testable import PixelPilot

/// The parser behind typing a figure into a readout.
///
/// Worth its own suite for a control whose failures are all quiet ones: nothing
/// crashes when `7` means 7 % instead of 70 %, or when `000` refuses instead of
/// meaning zero — the screen simply goes somewhere other than where it was told.
@Suite("Typed readout figures")
struct ReadoutInputTests {
  @Test("A figure is read as a percentage, not as a fraction")
  func plainFigures() {
    #expect(ReadoutInput.level(fromDigits: "40") == 0.4)
    #expect(ReadoutInput.level(fromDigits: "7") == 0.07)
    #expect(ReadoutInput.level(fromDigits: "100") == 1)
  }

  /// Zero is a value, not an absence. A parser returning nil here would make
  /// the one figure people type to turn something off the one figure that does
  /// nothing.
  @Test("Zero, however it is spelled")
  func zero() {
    #expect(ReadoutInput.level(fromDigits: "0") == 0)
    #expect(ReadoutInput.level(fromDigits: "00") == 0)
    #expect(ReadoutInput.level(fromDigits: "000") == 0)
  }

  @Test("Nothing typed means nothing to commit")
  func empty() {
    #expect(ReadoutInput.level(fromDigits: "") == nil)
    #expect(ReadoutInput.level(fromDigits: "abc") == nil)
  }

  /// The view caps input at three characters, so this can only be reached by a
  /// second caller — which is exactly why the function does not rely on the
  /// first one's manners.
  @Test("Out of range clamps rather than wrapping or overflowing")
  func clamped() {
    #expect(ReadoutInput.level(fromDigits: "999") == 1)
    #expect(ReadoutInput.level(fromDigits: "101") == 1)
    #expect(ReadoutInput.level(fromDigits: "99999999999999999999") == 1)
  }

  @Test("Non-digits are dropped rather than refused")
  func mixed() {
    #expect(ReadoutInput.level(fromDigits: "4 0") == 0.4)
    #expect(ReadoutInput.level(fromDigits: "40%") == 0.4)
  }
}
