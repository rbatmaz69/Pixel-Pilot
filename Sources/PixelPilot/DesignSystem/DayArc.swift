import PixelPilotCore
import SwiftUI

/// The day, drawn as an arc, with the schedule's stops sitting on it.
///
/// A list of times is accurate and says nothing about the shape of a day. The
/// arc makes "dim in the evening" a thing you can see rather than read, and
/// puts the stops in an order your eye already understands.
///
/// **The sun does not creep.** A `TimelineView` driving it in real time is the
/// obvious idea and is exactly the cost `AmbientBackdrop` explains at length: a
/// timeline re-runs its body on the main actor every frame, for a glyph nobody
/// is watching move. It is positioned when the view appears and when the
/// schedule changes, and animates to its new place with a spring.
struct DayArc: View {
  let stops: [ScheduleStop]
  /// 0...1 through the day, for the sun.
  let nowFraction: Double
  var selected: UUID?
  var onSelect: (UUID) -> Void = { _ in }
  /// Called with a new 0...1 position while a stop is dragged.
  var onMove: (UUID, Double) -> Void = { _, _ in }

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var dragging: UUID?

  private static let height: CGFloat = 96

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .topLeading) {
        arcPath(in: size)
          .stroke(.quaternary, style: StrokeStyle(lineWidth: 2, lineCap: .round))

        ForEach(stops) { stop in
          knob(stop, in: size)
        }

        sun(in: size)
      }
    }
    .frame(height: Self.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("The day, with scheduled changes on it")
  }

  // MARK: - Pieces

  /// A shallow arc — high at midday, low at both ends. Not a semicircle: a
  /// semicircle spends most of its width going nearly vertically, which puts
  /// the evening stops on top of each other.
  private func point(at fraction: Double, in size: CGSize) -> CGPoint {
    let x = size.width * fraction
    let arc = sin(fraction * .pi)
    let y = size.height - 18 - (size.height - 40) * arc
    return CGPoint(x: x, y: y)
  }

  private func arcPath(in size: CGSize) -> Path {
    var path = Path()
    for step in 0 ... 64 {
      let position = point(at: Double(step) / 64, in: size)
      if step == 0 { path.move(to: position) } else { path.addLine(to: position) }
    }
    return path
  }

  private func knob(_ stop: ScheduleStop, in size: CGSize) -> some View {
    let fraction = Self.fraction(of: stop, stops: stops)
    let position = point(at: fraction, in: size)
    let isSelected = selected == stop.id
    let isDragging = dragging == stop.id

    return VStack(spacing: 2) {
      Circle()
        .fill(tint(for: stop).accentFill)
        .frame(width: isDragging ? 16 : (isSelected ? 14 : 11))
        .overlay {
          Circle().strokeBorder(.background, lineWidth: 2)
        }
        .shadow(color: tint(for: stop).accentGlow(isSelected || isDragging), radius: 6)
    }
    .position(position)
    // The knob's size springs; its position does not, for the same reason the
    // slider handle's does not — while it is being dragged it has to be under
    // the pointer, not on its way there.
    .animation(motion.spatialFast, value: isDragging)
    .animation(isDragging ? nil : motion.spatialDefault, value: fraction)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { gesture in
          dragging = stop.id
          onSelect(stop.id)
          onMove(stop.id, min(1, max(0, gesture.location.x / size.width)))
        }
        .onEnded { _ in
          dragging = nil
          Haptics.detent()
        }
    )
    .accessibilityLabel(Self.label(for: stop))
  }

  private func sun(in size: CGSize) -> some View {
    let position = point(at: nowFraction, in: size)
    // Night is more of the arc than daylight for half the year, and a sun over
    // a dark schedule reads as wrong even when the position is right.
    let isDaytime = nowFraction > 0.25 && nowFraction < 0.8

    return Image(systemName: isDaytime ? "sun.max.fill" : "moon.fill")
      .font(.system(size: 13))
      .foregroundStyle(isDaytime ? Status.warn : .secondary)
      .position(position)
      .contentTransition(.symbolEffect(.replace))
      // Positioned on appearance and when the schedule changes, never per
      // frame. See the type documentation.
      .animation(motion.spatialSlow, value: nowFraction)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func tint(for stop: ScheduleStop) -> Color {
    guard let kelvin = stop.kelvin else { return theme.tone }
    let point = ColorTemperature.whitePoint(kelvin: kelvin)
    return Color(red: point.red, green: point.green, blue: point.blue)
  }

  // MARK: - Placement

  /// Where a stop sits along the arc.
  ///
  /// Clock stops go where the clock says. Solar stops have no fixed hour — that
  /// is the point of them — so they are placed at nominal positions and move
  /// only in the sense that what they mean moves. Showing them at a made-up
  /// exact time would be a lie about a value the user did not set.
  static func fraction(of stop: ScheduleStop, stops: [ScheduleStop]) -> Double {
    switch stop.time {
    case let .clock(hour, minute):
      return (Double(hour) + Double(minute) / 60) / 24
    case let .sunrise(offset):
      return min(1, max(0, (6.5 + Double(offset) / 60) / 24))
    case let .sunset(offset):
      return min(1, max(0, (19.5 + Double(offset) / 60) / 24))
    }
  }

  static func label(for stop: ScheduleStop) -> String {
    switch stop.time {
    case let .clock(hour, minute):
      String(format: "%02d:%02d", hour, minute)
    case let .sunrise(offset):
      offset == 0 ? "Sunrise" : "Sunrise \(offset > 0 ? "+" : "")\(offset) min"
    case let .sunset(offset):
      offset == 0 ? "Sunset" : "Sunset \(offset > 0 ? "+" : "")\(offset) min"
    }
  }
}
