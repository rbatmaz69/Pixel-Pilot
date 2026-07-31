import CoreGraphics

/// Turns the arrangement of screens into rectangles a view can draw.
///
/// This is in the tested package for one reason, and it is not the scaling.
/// AppKit's `NSScreen.frame` has its origin at the **bottom** left of the
/// desktop, and SwiftUI's coordinate space has its origin at the **top** left.
/// A map built without that flip looks perfectly correct on the single-screen
/// setup it was written on, and on the horizontal two-screen setup after that,
/// and is upside down the first time somebody stacks a monitor above their
/// laptop. That is precisely the class of bug that deserves a test instead of a
/// careful reading.
public enum DisplayLayout {
  /// Fits `frames` into `box`, preserving their relative positions and aspect
  /// ratios, and flipping to a top-left origin.
  ///
  /// Returns rectangles in the same order as the input, so callers can zip them
  /// back against whatever the frames belonged to.
  public static func normalize(
    frames: [CGRect], into box: CGRect, spacing: CGFloat = 4
  ) -> [CGRect] {
    guard !frames.isEmpty else { return [] }

    let desktop = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    guard desktop.width > 0, desktop.height > 0, box.width > 0, box.height > 0 else {
      return frames.map { _ in .zero }
    }

    // One scale for both axes, so a tall screen next to a wide one keeps being
    // taller. Scaling each axis to fit would make every arrangement fill the
    // box and none of them look like the desk it describes.
    let scale = min(box.width / desktop.width, box.height / desktop.height)
    let scaled = CGSize(width: desktop.width * scale, height: desktop.height * scale)
    let originX = box.minX + (box.width - scaled.width) / 2
    let originY = box.minY + (box.height - scaled.height) / 2

    return frames.map { frame in
      // The flip: distance from the *top* of the desktop, not the bottom.
      let fromTop = desktop.maxY - frame.maxY
      let rect = CGRect(
        x: originX + (frame.minX - desktop.minX) * scale,
        y: originY + fromTop * scale,
        width: frame.width * scale,
        height: frame.height * scale
      )
      // Inset for the gap between screens, never past nothing — a narrow screen
      // in a small box must not come out inside out.
      return rect.insetBy(
        dx: min(spacing / 2, rect.width / 2 - 0.5),
        dy: min(spacing / 2, rect.height / 2 - 0.5)
      )
    }
  }
}
