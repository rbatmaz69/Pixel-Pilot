import CoreGraphics
import Foundation

/// A rectangle on a display, as fractions of that display's frame, with the
/// origin at the **top left** — SwiftUI's corner, not AppKit's.
///
/// Fractions rather than points because a mark has to outlive a resolution
/// change: the panel is the same piece of glass at 1440p as at 4K, so the
/// fraction of the way across it that a bad pixel sits does not move. Points
/// would.
///
/// The origin is stated rather than assumed because `DisplayLayout` exists
/// entirely to fix having got this wrong once. The rule here is simpler than
/// the one there: nothing in this feature ever leaves SwiftUI's space. A mark
/// is placed in a gesture's local coordinates, stored as a fraction of the same
/// view, and drawn back into the same view. `NSScreen.frame` never enters, so
/// there is no flip to forget.
///
/// **What this does not survive**, all stated rather than worked around:
///
/// - **A rotated display.** The app has no rotation code, and a mark placed at
///   0° would come back somewhere else at 90°.
/// - **Mirroring.** `NSScreen.screens` collapses a mirror set to one entry, so
///   a mark placed on the mirror is stored against the primary's settings. The
///   test-pattern overlay has always had this.
/// - **A scaled mode.** A mark can be no finer than the logical framebuffer. On
///   a 4K panel running "looks like 1920×1080", one logical pixel is four
///   physical ones. Fine for exercising, imprecise as a record.
public struct NormalisedRect: Codable, Sendable, Equatable, Hashable {
  /// Never zero-area. A mark with no extent cannot be hit-tested and cannot be
  /// exercised, which are the only two things a mark is for.
  public static let minimumSide: Double = 1e-4

  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  /// Clamps rather than rejects, for the reason `ToneCurve.init` gives: these
  /// arrive from a gesture, from stored JSON written by another build, and from
  /// arithmetic near an edge. Out of range is something to bring into range.
  public init(x: Double, y: Double, width: Double, height: Double) {
    let left = min(max(0, x), 1)
    let top = min(max(0, y), 1)
    self.x = left
    self.y = top
    self.width = min(max(Self.minimumSide, width), 1 - left)
    self.height = min(max(Self.minimumSide, height), 1 - top)
  }

  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var midX: Double { x + width / 2 }
  public var midY: Double { y + height / 2 }

  /// A mark around a click.
  ///
  /// Sized in device pixels rather than points, because the thing being marked
  /// is a pixel. `pixelSize` is the view's size multiplied by its backing scale.
  ///
  /// This is the tight half of the feature's one deliberate asymmetry: **store
  /// tight, draw generous.** A few device pixels here is 0.0016 of the width on
  /// a 4K panel. The crop marks drawn around it are an order of magnitude
  /// bigger, and so is the hit-test tolerance — otherwise you either store a
  /// blob and lose the location, or store a point you can never click again.
  public static func around(
    _ point: CGPoint, sidePixels: Double, in pixelSize: CGSize
  ) -> NormalisedRect {
    guard pixelSize.width > 0, pixelSize.height > 0 else {
      return NormalisedRect(x: 0, y: 0, width: minimumSide, height: minimumSide)
    }
    let width = sidePixels / pixelSize.width
    let height = sidePixels / pixelSize.height
    return NormalisedRect(
      x: point.x / pixelSize.width - width / 2,
      y: point.y / pixelSize.height - height / 2,
      width: width,
      height: height
    )
  }

  public static func normalising(_ rect: CGRect, in size: CGSize) -> NormalisedRect {
    guard size.width > 0, size.height > 0 else {
      return NormalisedRect(x: 0, y: 0, width: minimumSide, height: minimumSide)
    }
    return NormalisedRect(
      x: rect.minX / size.width,
      y: rect.minY / size.height,
      width: rect.width / size.width,
      height: rect.height / size.height
    )
  }

  public func denormalised(in size: CGSize) -> CGRect {
    CGRect(
      x: x * size.width,
      y: y * size.height,
      width: width * size.width,
      height: height * size.height
    )
  }

  /// Whether a point in the same normalised space falls inside, allowing for a
  /// tolerance also expressed as a fraction.
  ///
  /// The tolerance is not politeness. A stored mark is a handful of device
  /// pixels across, and a mark you cannot click is a mark you cannot remove.
  public func contains(_ point: CGPoint, tolerance: Double = 0) -> Bool {
    point.x >= x - tolerance
      && point.x <= maxX + tolerance
      && point.y >= y - tolerance
      && point.y <= maxY + tolerance
  }

  public func nudged(dx: Double, dy: Double) -> NormalisedRect {
    NormalisedRect(
      x: min(max(0, x + dx), 1 - width),
      y: min(max(0, y + dy), 1 - height),
      width: width,
      height: height
    )
  }

  /// Grown about its own centre to at least `pixels` a side, without leaving
  /// the screen.
  ///
  /// For the repair pass: a mark six device pixels across is not worth handing
  /// to Core Animation as its own layer, and the cells immediately around a
  /// stuck one are worth working too — a sub-pixel that will not relax is
  /// rarely alone.
  public func grown(toAtLeastPixels pixels: Double, in pixelSize: CGSize) -> NormalisedRect {
    guard pixelSize.width > 0, pixelSize.height > 0 else { return self }
    let targetWidth = max(width, pixels / pixelSize.width)
    let targetHeight = max(height, pixels / pixelSize.height)
    // Returned unchanged rather than recomputed from the centre when it is
    // already big enough. Re-deriving an origin it already has would move the
    // mark by a float's worth of rounding every time this is called, and it is
    // called on every repair pass.
    guard targetWidth > width || targetHeight > height else { return self }
    return NormalisedRect(
      x: midX - targetWidth / 2,
      y: midY - targetHeight / 2,
      width: targetWidth,
      height: targetHeight
    )
  }

  /// Hand-written for the reason on `DisplaySettings.init(from:)`.
  ///
  /// Every key falls back to zero rather than throwing, and the clamping `init`
  /// then turns that into the minimum square at the top-left corner. A mark in
  /// the wrong place is visible and removable; a throw here would take the
  /// whole array with it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0,
      y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0,
      width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 0,
      height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
    )
  }
}
