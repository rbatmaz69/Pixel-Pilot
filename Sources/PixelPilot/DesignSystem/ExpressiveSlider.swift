import PixelPilotCore
import SwiftUI

/// The signature control of the app.
///
/// A macOS slider in every way that matters — size, spacing, keyboard and
/// VoiceOver behaviour — with Material 3 Expressive movement layered on top:
/// the handle morphs from a thin pill to a wide squircle as you grab it, the
/// track thickens, and everything settles with a spring rather than an ease.
///
/// Two properties that are easy to lose and expensive to get back:
///
/// - **Dragging is not animated.** The handle follows the pointer exactly; only
///   the *shape* change is sprung. A sprung position lags the cursor and feels
///   broken.
/// - **`onCommit` fires once, on release.** Callers use it for the expensive,
///   verified write. Firing it continuously would put a DDC round trip in the
///   middle of every drag.
struct ExpressiveSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double> = 0 ... 1
  var accent: Color
  var icon: String?
  /// Overrides the accent fill on the filled part of the track.
  ///
  /// Exists for the warmth control, whose track is a Kelvin gradient built from
  /// the same function that drives the hardware — so the colour under the
  /// handle is the colour the screen is about to be. Defaulted to nil, so no
  /// existing call site changes.
  var trackStyle: AnyShapeStyle?
  /// Marks that tug back, as 0...1 fractions of the track. Felt and drawn,
  /// never enforced — see `SliderDetents`.
  ///
  /// Defaulted rather than passed at each call site: every slider in this app
  /// is a percentage of something, so the quarters are the right marks for all
  /// of them, and six copies of the same argument is how the seventh ends up
  /// different. Pass an empty array for a control where they are not.
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
  /// Bumped to fire the knob's squash. One counter for both causes — arriving
  /// at an end and letting go — because they want the same acknowledgement.
  @State private var pop = 0
  /// Bumped when a detent is entered. Its own counter, and its own smaller
  /// squash: a detent happens several times in one drag and must not read as
  /// loudly as bottoming out.
  @State private var tick = 0
  /// Latches the end stop, so holding the pointer past the edge pops once
  /// instead of on every frame of the drag.
  @State private var isAtEnd = false
  /// The detent currently occupied. Latched for the same reason as `isAtEnd`:
  /// a drag sits inside a detent for many frames and deserves one tick.
  @State private var latchedDetent: Double?

  /// How wide a detent feels, in points. Converted to a fraction of the track
  /// at drag time so a wide slider does not get wide detents.
  private static let detentReach: Double = 4

  private var fraction: Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(1, max(0, (value - range.lowerBound) / span))
  }

  private var metrics: KnobGeometry.Metrics {
    KnobGeometry.metrics(isDragging: isDragging, isHovered: isHovered)
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let knobTravel = max(1, width - metrics.width)
      let knobX = knobTravel * fraction + metrics.width / 2

      ZStack(alignment: .leading) {
        track(width: width, filledTo: knobX)
        knob(centeredAt: knobX, height: geometry.size.height)
      }
      .frame(height: geometry.size.height)
      .contentShape(.rect)
      .gesture(dragGesture(width: width))
    }
    .frame(height: KnobGeometry.dragging.trackHeight + 12)
    .onHover { hovering in
      // Hover is a pure effect change, so it gets an effect spring — and it is
      // suppressed mid-drag, where the pointer routinely leaves the control.
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
    ZStack(alignment: .leading) {
      MorphingRoundedRectangle(cornerRadius: metrics.trackHeight / 2)
        .fill(.quaternary)

      detentMarks(width: width)

      MorphingRoundedRectangle(cornerRadius: metrics.trackHeight / 2)
        .fill(trackStyle ?? AnyShapeStyle(theme.fill(for: accent)))
        .frame(width: max(metrics.trackHeight, knobX))

      if let icon {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.leading, 6)
          // Hidden once the fill is too narrow to hold it, rather than letting
          // it spill onto the empty part of the track.
          .opacity(knobX > 22 ? 1 : 0)
          .animation(motion.effectFast, value: knobX > 22)
      }
    }
    .frame(width: width, height: metrics.trackHeight)
    .animation(motion.spatialFast, value: metrics.trackHeight)
  }

  /// Hairlines where the detents are.
  ///
  /// A detent nobody can see is a control that occasionally resists for no
  /// stated reason. Drawn under the fill rather than over it, so the marks show
  /// on the empty part of the track and the filled part stays a clean colour —
  /// ticks over the accent read as damage to it.
  ///
  /// The two ends are skipped: a mark hard against the cap is indistinguishable
  /// from the cap.
  @ViewBuilder
  private func detentMarks(width: CGFloat) -> some View {
    let interior = detents.filter { $0 > 0.001 && $0 < 0.999 }
    if !interior.isEmpty {
      ZStack(alignment: .leading) {
        ForEach(interior, id: \.self) { detent in
          Rectangle()
            .fill(.tertiary)
            .frame(width: 1, height: metrics.trackHeight)
            // The knob's own formula, minus half the mark's width to centre it
            // on the line rather than start it there. Sharing the formula
            // matters more than it looks: `metrics.width` grows when the handle
            // is grabbed, and a mark computed any other way would drift out
            // from under a handle that is sitting still on it.
            .offset(x: (width - metrics.width) * detent + metrics.width / 2 - 0.5)
        }
      }
      .frame(width: width, alignment: .leading)
      // The marks belong to the track, so they fade with it rather than
      // sitting at full strength on a control nobody is touching.
      .opacity(isDragging || isHovered ? 0.9 : 0.5)
      .animation(motion.effectFast, value: isDragging || isHovered)
    }
  }

  private func knob(centeredAt x: CGFloat, height: CGFloat) -> some View {
    MorphingKnob(width: metrics.width, cornerRadius: metrics.cornerRadius)
      .fill(.white)
      .shadow(color: .black.opacity(isDragging ? 0.30 : 0.16), radius: isDragging ? 6 : 2, y: 1)
      .background { glow }
      .frame(width: metrics.width, height: metrics.trackHeight + (isDragging ? 10 : 6))
      .tickOnChange(tick, motion: motion)
      .squashOnChange(pop, motion: motion)
      .position(x: x, y: height / 2)
      // The morph springs; the position does not. Position must track the
      // pointer exactly or the control feels laggy. Everything added around
      // this control since — entrances, glows, the squash — is keyed to its own
      // value for exactly this reason: an unkeyed animation, or a
      // `withAnimation` anywhere above, would reach the position and undo it.
      .animation(motion.spatialFast, value: metrics)
      .animation(nil, value: x)
  }

  /// The accent halo under the handle while it is held.
  ///
  /// Its own layer with its own spring: opacity is an effect and must not
  /// overshoot, but the morph it sits behind is spatial and must. Sharing one
  /// curve would make the glow flicker at the end of every grab.
  private var glow: some View {
    MorphingKnob(width: metrics.width, cornerRadius: metrics.cornerRadius)
      .fill(accent)
      .blur(radius: 7)
      .opacity(isDragging ? 0.9 : 0)
      .animation(motion.effectDefault, value: isDragging)
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
