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

  /// Fits top-down Quartz display frames (`CGDisplayBounds`, where Y grows
  /// downward from the primary top-left origin) into `box`, preserving aspect
  /// ratios without inverting the Y axis.
  public static func normalizeTopDown(
    frames: [CGRect], into box: CGRect, spacing: CGFloat = 4
  ) -> [CGRect] {
    guard !frames.isEmpty else { return [] }

    let desktop = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    guard desktop.width > 0, desktop.height > 0, box.width > 0, box.height > 0 else {
      return frames.map { _ in .zero }
    }

    let scale = min(box.width / desktop.width, box.height / desktop.height)
    let scaled = CGSize(width: desktop.width * scale, height: desktop.height * scale)
    let originX = box.minX + (box.width - scaled.width) / 2
    let originY = box.minY + (box.height - scaled.height) / 2

    return frames.map { frame in
      let rect = CGRect(
        x: originX + (frame.minX - desktop.minX) * scale,
        y: originY + (frame.minY - desktop.minY) * scale,
        width: frame.width * scale,
        height: frame.height * scale
      )
      return rect.insetBy(
        dx: min(spacing / 2, rect.width / 2 - 0.5),
        dy: min(spacing / 2, rect.height / 2 - 0.5)
      )
    }
  }

  /// Scale factor mapping global display coordinates into `box`.
  public static func scaleFactor(frames: [CGRect], into box: CGRect) -> CGFloat {
    guard let first = frames.first else { return 1 }
    let desktop = frames.dropFirst().reduce(first) { $0.union($1) }
    guard desktop.width > 0, desktop.height > 0, box.width > 0, box.height > 0 else { return 1 }
    return min(box.width / desktop.width, box.height / desktop.height)
  }

  // MARK: - Interactive 2D Snapping & Primary Display Normalization

  /// A magnetic alignment guideline emitted while arranging displays in 2D space.
  public struct AlignmentGuide: Sendable, Equatable, Hashable {
    public enum Axis: Sendable, Equatable, Hashable {
      case horizontal
      case vertical
    }

    public let axis: Axis
    /// Coordinate in global display space (Y for horizontal, X for vertical).
    public let position: CGFloat

    public init(axis: Axis, position: CGFloat) {
      self.axis = axis
      self.position = position
    }
  }

  /// Output of `DisplayLayout.snap(moving:against:threshold:)`.
  public struct SnapResult: Sendable, Equatable {
    public let frame: CGRect
    public let guides: [AlignmentGuide]

    public init(frame: CGRect, guides: [AlignmentGuide]) {
      self.frame = frame
      self.guides = guides
    }
  }

  /// A display identifier paired with its global Quartz bounds.
  public struct ArrangementEntry: Sendable, Equatable, Hashable {
    public let id: UInt32
    public var frame: CGRect

    public init(id: UInt32, frame: CGRect) {
      self.id = id
      self.frame = frame
    }
  }

  /// Docks `moving` seamlessly edge-to-edge against `stationary` displays so there are
  /// no dead pointer gaps and no interior overlaps, while magnetically snapping edges and
  /// center axes within `threshold` global units.
  public static func snap(
    moving: CGRect,
    against stationary: [CGRect],
    threshold: CGFloat = 24
  ) -> SnapResult {
    guard !stationary.isEmpty else {
      return SnapResult(frame: moving, guides: [])
    }

    var bestFrame: CGRect?
    var bestGuides: [AlignmentGuide] = []
    var bestDistance = CGFloat.greatestFiniteMagnitude

    for target in stationary {
      let candidates: [CGRect] = [
        // Dock left of target
        snappedYCandidate(
          x: target.minX - moving.width,
          desiredY: moving.minY,
          movingSize: moving.size,
          against: target,
          threshold: threshold
        ).frame,
        // Dock right of target
        snappedYCandidate(
          x: target.maxX,
          desiredY: moving.minY,
          movingSize: moving.size,
          against: target,
          threshold: threshold
        ).frame,
        // Dock above target (smaller minY in top-down space)
        snappedXCandidate(
          y: target.minY - moving.height,
          desiredX: moving.minX,
          movingSize: moving.size,
          against: target,
          threshold: threshold
        ).frame,
        // Dock below target (larger maxY in top-down space)
        snappedXCandidate(
          y: target.maxY,
          desiredX: moving.minX,
          movingSize: moving.size,
          against: target,
          threshold: threshold
        ).frame,
      ]

      for candidate in candidates {
        let overlaps = stationary.contains { other in
          candidate.insetBy(dx: 0.5, dy: 0.5).intersects(other)
        }
        guard !overlaps else { continue }

        let dx = candidate.midX - moving.midX
        let dy = candidate.midY - moving.midY
        let distance = dx * dx + dy * dy
        if distance < bestDistance {
          bestDistance = distance
          bestFrame = candidate
        }
      }
    }

    let resolved: CGRect
    if let bestFrame {
      resolved = bestFrame
    } else {
      // Fallback: place cleanly to the right of the stationary bounding box.
      let union = stationary.dropFirst().reduce(stationary[0]) { $0.union($1) }
      resolved = CGRect(x: union.maxX, y: union.minY, width: moving.width, height: moving.height)
    }

    bestGuides = alignmentGuides(for: resolved, against: stationary)
    return SnapResult(frame: resolved, guides: bestGuides)
  }

  /// Translates all display origins so the chosen primary display sits at `(0, 0)`.
  public static func assignPrimary(
    id: UInt32,
    in entries: [ArrangementEntry]
  ) -> [ArrangementEntry] {
    guard let primary = entries.first(where: { $0.id == id }) else { return entries }
    let dx = -primary.frame.minX
    let dy = -primary.frame.minY
    return entries.map { entry in
      var updated = entry
      updated.frame.origin.x += dx
      updated.frame.origin.y += dy
      return updated
    }
  }

  private static func snappedYCandidate(
    x: CGFloat,
    desiredY: CGFloat,
    movingSize: CGSize,
    against target: CGRect,
    threshold: CGFloat
  ) -> (frame: CGRect, snapped: Bool) {
    let anchors: [CGFloat] = [
      target.minY,
      target.maxY - movingSize.height,
      target.midY - movingSize.height / 2,
    ]
    let minAllowedY = target.minY - movingSize.height
    let maxAllowedY = target.maxY
    let clampedDesired = min(maxAllowedY, max(minAllowedY, desiredY))

    if let match = closestAnchor(to: desiredY, among: anchors, threshold: threshold) {
      let clampedMatch = min(maxAllowedY, max(minAllowedY, match))
      return (CGRect(origin: CGPoint(x: x, y: clampedMatch), size: movingSize), true)
    }
    return (CGRect(origin: CGPoint(x: x, y: clampedDesired), size: movingSize), false)
  }

  private static func snappedXCandidate(
    y: CGFloat,
    desiredX: CGFloat,
    movingSize: CGSize,
    against target: CGRect,
    threshold: CGFloat
  ) -> (frame: CGRect, snapped: Bool) {
    let anchors: [CGFloat] = [
      target.minX,
      target.maxX - movingSize.width,
      target.midX - movingSize.width / 2,
    ]
    let minAllowedX = target.minX - movingSize.width
    let maxAllowedX = target.maxX
    let clampedDesired = min(maxAllowedX, max(minAllowedX, desiredX))

    if let match = closestAnchor(to: desiredX, among: anchors, threshold: threshold) {
      let clampedMatch = min(maxAllowedX, max(minAllowedX, match))
      return (CGRect(origin: CGPoint(x: clampedMatch, y: y), size: movingSize), true)
    }
    return (CGRect(origin: CGPoint(x: clampedDesired, y: y), size: movingSize), false)
  }

  private static func closestAnchor(
    to value: CGFloat,
    among anchors: [CGFloat],
    threshold: CGFloat
  ) -> CGFloat? {
    var bestAnchor: CGFloat?
    var bestDelta = threshold
    for anchor in anchors {
      let delta = abs(anchor - value)
      if delta <= bestDelta {
        bestDelta = delta
        bestAnchor = anchor
      }
    }
    return bestAnchor
  }

  private static func alignmentGuides(
    for frame: CGRect,
    against stationary: [CGRect]
  ) -> [AlignmentGuide] {
    var seen = Set<AlignmentGuide>()
    var guides: [AlignmentGuide] = []
    let epsilon: CGFloat = 0.5

    for target in stationary {
      let xPairs: [(CGFloat, CGFloat)] = [
        (frame.minX, target.minX),
        (frame.maxX, target.maxX),
        (frame.midX, target.midX),
      ]
      for (a, b) in xPairs where abs(a - b) <= epsilon {
        let guide = AlignmentGuide(axis: .vertical, position: b)
        if seen.insert(guide).inserted { guides.append(guide) }
      }

      let yPairs: [(CGFloat, CGFloat)] = [
        (frame.minY, target.minY),
        (frame.maxY, target.maxY),
        (frame.midY, target.midY),
      ]
      for (a, b) in yPairs where abs(a - b) <= epsilon {
        let guide = AlignmentGuide(axis: .horizontal, position: b)
        if seen.insert(guide).inserted { guides.append(guide) }
      }
    }
    return guides
  }
}
