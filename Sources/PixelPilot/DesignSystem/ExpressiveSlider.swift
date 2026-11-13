import PixelPilotCore
import SwiftUI

/// Native macOS Control Center Pill Slider with Warm Studio Craft tactile details.
///
/// Combines a `26pt` recessed Control Center pill track (`theme.recessedWell`),
/// crisp warm-ivory fill (`theme.sliderFill`), fine engraved Leica-aperture
/// scale ticks (`.cc-scale-ticks`) with magnetic quarter detents (`25% / 50% / 75%`),
/// a rotating leading sun glyph, a circular native thumb that reveals on
/// hover/drag, and a glowing ghost preview bridge when hovering a scene preset.
///
/// Two invariants:
/// - **Dragging is not animated.** The handle follows the pointer with `0ms` lag.
/// - **`onCommit` fires once, on release.**
struct ExpressiveSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double> = 0 ... 1
  var accent: Color
  var icon: String?
  /// Overrides the fill on the filled part of the track (e.g. Kelvin warmth gradient).
  var trackStyle: AnyShapeStyle?
  /// Preview target position (in the same units as `value`) when hovering a preset scene.
  var ghost: Double?
  /// Marks that tug back with haptic feedback, as `0...1` fractions of the track.
  var detents: [Double] = SliderDetents.quarters
  /// Called continuously while dragging — cheap work only.
  var onChange: (Double) -> Void = { _ in }
  /// Called once when the drag ends.
  var onCommit: (Double) -> Void = { _ in }

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  @State private var isDragging = false
  @State private var isHovered = false
  @State private var pop = 0
  @State private var tick = 0
  @State private var isAtEnd = false
  @State private var latchedDetent: Double?

  /// How wide a detent feels, in points.
  private static let detentReach: Double = 4
  /// Engraved Leica-style decile scale marks across the pill track.
  private static let scaleDeciles: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

  private var fraction: Double { fraction(of: value) }

  private func fraction(of value: Double) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(1, max(0, (value - range.lowerBound) / span))
  }

  /// Where the centre of the thumb sits for a fraction of the track.
  private func knobX(for fraction: Double, width: CGFloat) -> CGFloat {
    max(1, width - metrics.width) * fraction + metrics.width / 2
  }

  private var metrics: KnobGeometry.Metrics {
    KnobGeometry.metrics(isDragging: isDragging, isHovered: isHovered)
  }

  private var rotatesGlyph: Bool {
    guard let icon else { return false }
    return icon.contains("sun") || icon.contains("sparkles")
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let handleX = knobX(for: fraction, width: width)

      ZStack(alignment: .leading) {
        track(width: width, filledTo: handleX)

        if let ghost, !isDragging {
          ghostMarker(
            at: knobX(for: fraction(of: ghost), width: width),
            from: handleX,
            width: width,
            height: geometry.size.height
          )
        }

        knob(centeredAt: handleX, height: geometry.size.height)
      }
      .frame(height: geometry.size.height)
      .contentShape(.rect)
      .gesture(dragGesture(width: width))
      .animation(motion.effectDefault, value: ghost)
    }
    .frame(height: KnobGeometry.rest.trackHeight)
    .onHover { hovering in
      withAnimation(motion.effectFast) {
        isHovered = hovering && !isDragging
      }
    }
    .opacity(isEnabled ? 1 : 0.4)
    .accessibilityElement()
    .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    .accessibilityAdjustableAction { direction in
      let step = 1.0 / 16.0
      let delta = direction == .increment ? step : -step
      let updated = min(range.upperBound, max(range.lowerBound, value + delta))
      value = updated
      onChange(updated)
      onCommit(updated)
    }
  }

  // MARK: - Pieces

  private func track(width: CGFloat, filledTo knobX: CGFloat) -> some View {
    let fillWidth = max(metrics.trackHeight, min(width, knobX + metrics.width / 2))
    let pillShape = Capsule(style: .continuous)

    return ZStack(alignment: .leading) {
      // Recessed Control Center well
      pillShape
        .fill(theme.recessedWell)
        .overlay {
          pillShape.strokeBorder(theme.groupBorder, lineWidth: 1)
        }

      // Crisp warm-ivory / custom fill bar
      pillShape
        .fill(resolvedFillStyle)
        .frame(width: fillWidth)
        .shadow(color: .black.opacity(0.10), radius: 2, x: 1, y: 0)

      // Fine engraved Leica aperture scale ticks + prominent quarter detents
      scaleAndDetentMarks(width: width, fillWidth: fillWidth)

      // Embedded leading glyph with smooth sun rotation
      if let icon {
        let isCovered = fillWidth > 26
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(
            isCovered
              ? (trackStyle == nil ? theme.sliderGlyphInk.opacity(0.82) : Color.white.opacity(0.92))
              : Color.secondary
          )
          .rotationEffect(.degrees(rotatesGlyph ? fraction * 90 : 0))
          .scaleEffect(rotatesGlyph ? (0.92 + 0.14 * fraction) : 1.0)
          .padding(.leading, 8)
          .allowsHitTesting(false)
      }
    }
    .frame(width: width, height: metrics.trackHeight)
    .clipShape(pillShape)
  }

  private var resolvedFillStyle: AnyShapeStyle {
    if let trackStyle {
      return trackStyle
    }
    return AnyShapeStyle(
      LinearGradient(
        colors: [
          theme.sliderFill,
          theme.sliderFill.blended(with: accent, by: isDragging ? 0.14 : 0.06),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  /// Engraved Leica aperture scale ticks (every 10%) plus magnetic quarter detent ticks (`25% / 50% / 75%`).
  @ViewBuilder
  private func scaleAndDetentMarks(width: CGFloat, fillWidth: CGFloat) -> some View {
    let interiorDetents = detents.filter { $0 > 0.001 && $0 < 0.999 }
    ZStack(alignment: .leading) {
      // Fine decile scale ticks along bottom edge
      ForEach(Self.scaleDeciles, id: \.self) { mark in
        let markX = knobX(for: mark, width: width)
        let isCovered = markX < fillWidth
        Rectangle()
          .fill(
            isCovered
              ? theme.sliderGlyphInk.opacity(isDragging || isHovered ? 0.24 : 0.12)
              : Color.primary.opacity(isDragging || isHovered ? 0.26 : 0.12)
          )
          .frame(width: 1, height: 3.5)
          .offset(x: markX - 0.5, y: metrics.trackHeight / 2 - 3.5)
      }

      // Prominent quarter detent marks (25% / 50% / 75%)
      ForEach(interiorDetents, id: \.self) { detent in
        let detentX = knobX(for: detent, width: width)
        let isLatched = latchedDetent == detent && isDragging
        let isCovered = detentX < fillWidth
        Capsule(style: .continuous)
          .fill(
            isLatched
              ? theme.studioAccent
              : (isCovered
                ? theme.sliderGlyphInk.opacity(isDragging || isHovered ? 0.42 : 0.22)
                : Color.primary.opacity(isDragging || isHovered ? 0.42 : 0.22))
          )
          .frame(width: isLatched ? 2 : 1.25, height: isLatched ? 8 : 5.5)
          .offset(x: detentX - (isLatched ? 1 : 0.625), y: metrics.trackHeight / 2 - (isLatched ? 5.5 : 4.5))
      }
    }
    .frame(width: width, height: metrics.trackHeight, alignment: .leading)
    .allowsHitTesting(false)
    .animation(motion.effectFast, value: isDragging || isHovered)
    .animation(motion.effectFast, value: latchedDetent)
  }

  /// Ghost preview bridge & hollow target ring when hovering a scene card.
  private func ghostMarker(
    at x: CGFloat, from handleX: CGFloat, width: CGFloat, height: CGFloat
  ) -> some View {
    ZStack {
      Capsule(style: .continuous)
        .fill(theme.studioAccent.opacity(0.55))
        .frame(width: max(3, abs(x - handleX)), height: 4)
        .position(x: (x + handleX) / 2, y: height / 2)

      Circle()
        .strokeBorder(theme.studioAccent, lineWidth: 2)
        .background(Circle().fill(theme.sliderFill.opacity(0.35)))
        .frame(width: 16, height: 16)
        .shadow(color: theme.studioAccent.opacity(0.45), radius: 4)
        .position(x: x, y: height / 2)
    }
    .frame(width: width, height: height)
    .allowsHitTesting(false)
    .transition(.opacity)
  }

  /// Native circular Control Center thumb (`20×20pt`) that reveals on hover/drag.
  private func knob(centeredAt x: CGFloat, height: CGFloat) -> some View {
    let isActive = isDragging || isHovered
    return Circle()
      .fill(Color.white)
      .overlay {
        Circle()
          .strokeBorder(
            isDragging ? theme.studioAccent.opacity(0.65) : Color.black.opacity(0.12),
            lineWidth: isDragging ? 1.5 : 0.75
          )
      }
      .shadow(color: .black.opacity(isDragging ? 0.26 : 0.18), radius: isDragging ? 5 : 3, y: 1)
      .frame(width: metrics.width, height: metrics.width)
      .scaleEffect(isDragging ? 1.04 : (isHovered ? 1.0 : 0.86))
      .opacity(isActive ? 1 : 0)
      .position(x: x, y: height / 2)
      .animation(motion.effectFast, value: isActive)
      .animation(motion.effectFast, value: isDragging)
      .animation(nil, value: x)
  }

  // MARK: - Interaction

  private func dragGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { gesture in
        if !isDragging {
          withAnimation(motion.spatialFast) {
            isDragging = true
            isHovered = false
          }
        }
        update(to: gesture.location.x, width: width)
        onChange(value)
      }
      .onEnded { gesture in
        update(to: gesture.location.x, width: width)
        withAnimation(motion.spatialDefault) {
          isDragging = false
        }
        isAtEnd = false
        latchedDetent = nil
        // No haptic here on purpose. Letting go already has the squash, and a
        // tap on every release would fire far more often than the two things
        // worth feeling — bottoming out, and crossing a mark.
        pop += 1
        onCommit(value)
      }
  }

  private func update(to x: CGFloat, width: CGFloat) {
    let travel = max(1, width - metrics.width)
    let position = min(1, max(0, (x - metrics.width / 2) / travel))

    // Arriving at either end is worth feeling, so you can tell you have bottomed
    // out without reading the number. Latched, because the pointer usually keeps
    // going once it gets there.
    let reachedEnd = position <= 0 || position >= 1
    if reachedEnd, !isAtEnd {
      pop += 1
      Haptics.endStop()
    }
    isAtEnd = reachedEnd

    // The same latching idea one level down. Note what this does *not* do: it
    // never touches `position`. A detent that snapped the value would quantise
    // the one property this control promises to keep exact — the handle under
    // the pointer — and would make fine adjustment impossible on the control
    // whose entire job is fine adjustment. The mark is felt and drawn; the
    // number does whatever the pointer says.
    let detent = SliderDetents.nearest(
      to: position,
      among: detents,
      tolerance: SliderDetents.tolerance(points: Self.detentReach, travel: travel)
    )
    if let detent, detent != latchedDetent, !reachedEnd {
      tick += 1
      Haptics.detent()
    }
    latchedDetent = detent

    value = range.lowerBound + position * (range.upperBound - range.lowerBound)
  }
}
