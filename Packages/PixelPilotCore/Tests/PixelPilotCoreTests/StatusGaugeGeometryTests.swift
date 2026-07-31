import CoreGraphics
import Testing

@testable import PixelPilotCore

@Suite("Status gauge geometry")
struct StatusGaugeGeometryTests {
  private let bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
  private let inset: CGFloat = 3

  /// The two ends are where a gauge goes wrong, and they are the two states
  /// that are on screen the longest.
  @Test("Empty is empty, not a hairline")
  func zeroIsEmpty() {
    let rect = StatusGaugeGeometry.fillRect(for: 0, in: bounds, inset: inset)
    #expect(rect == .zero)
  }

  @Test("Full fills exactly to the inset, never past it")
  func oneFillsTheWell() {
    let rect = StatusGaugeGeometry.fillRect(for: 1, in: bounds, inset: inset)
    #expect(rect == CGRect(x: 3, y: 3, width: 12, height: 12))
  }

  @Test("Half fills half the well")
  func halfIsHalf() {
    let rect = StatusGaugeGeometry.fillRect(for: 0.5, in: bounds, inset: inset)
    #expect(rect.height == 6)
    #expect(rect.minY == 3, "it grows from the bottom")
  }

  /// The value comes from a monitor, and monitors report nonsense. A gauge is
  /// not the place to find that out.
  @Test("Values outside the range clamp instead of overflowing")
  func clampsOutOfRange() {
    let over = StatusGaugeGeometry.fillRect(for: 1.4, in: bounds, inset: inset)
    #expect(over == StatusGaugeGeometry.fillRect(for: 1, in: bounds, inset: inset))

    let under = StatusGaugeGeometry.fillRect(for: -0.3, in: bounds, inset: inset)
    #expect(under == .zero, "and never a negative height")
  }

  @Test("Fill height only ever increases with level")
  func isMonotonic() {
    var previous: CGFloat = -1
    for step in 0 ... 20 {
      let rect = StatusGaugeGeometry.fillRect(
        for: Double(step) / 20, in: bounds, inset: inset
      )
      #expect(rect.height >= previous)
      previous = rect.height
    }
  }

  @Test("An inset with no room left produces nothing")
  func degenerateInset() {
    #expect(StatusGaugeGeometry.fillRect(for: 1, in: bounds, inset: 9) == .zero)
    #expect(StatusGaugeGeometry.fillRect(for: 1, in: bounds, inset: 40) == .zero)
  }
}
