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
  /// Called with a 0...1 position while the pointer is over the arc, and with
  /// nil when it leaves. Nothing is written — see `scrubHead`.
  var onScrub: (Double?) -> Void = { _ in }

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var scheme
  @State private var dragging: UUID?
  @State private var scrubbed: Double?

  private static let height: CGFloat = 124

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .topLeading) {
        horizonBackdrop(in: size)

        solarHorizonGuides(in: size)

        // Glowing solar trajectory path
        arcPath(in: size)
          .stroke(
            LinearGradient(
              colors: [
                Color.white.opacity(0.16),
                theme.studioAccent.opacity(0.65),
                Color(.sRGB, red: 0.98, green: 0.78, blue: 0.42, opacity: 0.85),
                theme.studioAccent.opacity(0.65),
                Color.white.opacity(0.16),
              ],
              startPoint: .leading,
              endPoint: .trailing
            ),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
          )

        scrubHead(in: size)

        ForEach(stops) { stop in
          knob(stop, in: size)
        }

        sun(in: size)
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Layout.radiusCard, style: .continuous)
          .strokeBorder(theme.groupBorder, lineWidth: 1)
      )
      .contentShape(.rect)
      // Hover rather than drag, and that is the whole reason this reads as
      // looking rather than as editing. A drag here would have to be told apart
      // from dragging a stop, and would fight the scroll view the card sits in;
      // hovering has neither problem, and asking a question by pointing at it
      // is a lighter act than asking by grabbing.
      //
      // Attached to the container so it keeps reporting while the pointer
      // passes over a stop's knob. The head is suppressed during a drag, so
      // moving a stop never turns into two markers.
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case let .active(point):
          guard size.width > 0 else { return }
          let fraction = min(1, max(0, Double(point.x / size.width)))
          scrubbed = fraction
          onScrub(fraction)
        case .ended:
          scrubbed = nil
          onScrub(nil)
        }
      }
    }
    .frame(height: Self.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("The day, with scheduled changes on it")
  }

  // MARK: - Pieces

  /// Warm Tageshorizont-Panorama backdrop with night-to-noon-to-night sky
  /// gradient and layered studio hills along the bottom edge.
  private func horizonBackdrop(in size: CGSize) -> some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: Color(.sRGB, red: 0.09, green: 0.09, blue: 0.15, opacity: scheme == .dark ? 0.88 : 0.22), location: 0.0),
          .init(color: Color(.sRGB, red: 0.82, green: 0.45, blue: 0.22, opacity: scheme == .dark ? 0.42 : 0.24), location: 0.27),
          .init(color: Color(.sRGB, red: 0.96, green: 0.76, blue: 0.44, opacity: scheme == .dark ? 0.34 : 0.28), location: 0.50),
          .init(color: Color(.sRGB, red: 0.80, green: 0.38, blue: 0.20, opacity: scheme == .dark ? 0.45 : 0.25), location: 0.81),
          .init(color: Color(.sRGB, red: 0.09, green: 0.09, blue: 0.15, opacity: scheme == .dark ? 0.88 : 0.22), location: 1.0),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )

      // Distant warm ridge
      Path { path in
        let w = size.width
        let h = size.height
        path.move(to: CGPoint(x: 0, y: h * 0.78))
        path.addQuadCurve(
          to: CGPoint(x: w * 0.46, y: h * 0.74),
          control: CGPoint(x: w * 0.22, y: h * 0.62)
        )
        path.addQuadCurve(
          to: CGPoint(x: w, y: h * 0.76),
          control: CGPoint(x: w * 0.74, y: h * 0.60)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
      }
      .fill(
        LinearGradient(
          colors: [
            theme.studioAccent.opacity(scheme == .dark ? 0.20 : 0.14),
            Color.black.opacity(scheme == .dark ? 0.36 : 0.08),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )

      // Foreground walnut hill silhouette
      Path { path in
        let w = size.width
        let h = size.height
        path.move(to: CGPoint(x: 0, y: h * 0.85))
        path.addQuadCurve(
          to: CGPoint(x: w * 0.55, y: h * 0.83),
          control: CGPoint(x: w * 0.30, y: h * 0.92)
        )
        path.addQuadCurve(
          to: CGPoint(x: w, y: h * 0.82),
          control: CGPoint(x: w * 0.80, y: h * 0.72)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
      }
      .fill(
        Color(.sRGB, red: 0.14, green: 0.10, blue: 0.08, opacity: scheme == .dark ? 0.55 : 0.14)
      )
    }
    .allowsHitTesting(false)
  }

  private func solarHorizonGuides(in size: CGSize) -> some View {
    let sunriseX = size.width * (6.5 / 24.0)
    let sunsetX = size.width * (19.5 / 24.0)
    return ZStack {
      Path { path in
        path.move(to: CGPoint(x: sunriseX, y: 12))
        path.addLine(to: CGPoint(x: sunriseX, y: size.height - 10))
        path.move(to: CGPoint(x: sunsetX, y: 12))
        path.addLine(to: CGPoint(x: sunsetX, y: size.height - 10))
      }
      .stroke(
        theme.separator,
        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
      )
    }
    .allowsHitTesting(false)
  }

  /// A shallow arc — high at midday, low at both ends. Not a semicircle: a
  /// semicircle spends most of its width going nearly vertically, which puts
  /// the evening stops on top of each other.
  private func point(at fraction: Double, in size: CGSize) -> CGPoint {
    let x = size.width * fraction
    let arc = sin(fraction * .pi)
    let y = size.height - 22 - (size.height - 48) * arc
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
    let stopTint = tint(for: stop)
    let diameter: CGFloat = isDragging ? 18 : (isSelected ? 15 : 12)

    return ZStack {
      // Vertical pin stem to the horizon baseline
      Rectangle()
        .fill(
          LinearGradient(
            colors: [
              stopTint.opacity(isSelected || isDragging ? 0.75 : 0.35),
              .clear,
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: isSelected || isDragging ? 2 : 1, height: max(0, size.height - position.y - 8))
        .position(x: position.x, y: position.y + max(0, size.height - position.y - 8) / 2)
        .allowsHitTesting(false)

      // Tactile stop pin head
      Circle()
        .fill(theme.fill(for: stopTint))
        .frame(width: diameter, height: diameter)
        .overlay {
          Circle().strokeBorder(.background, lineWidth: 2)
        }
        .shadow(
          color: theme.glow(for: stopTint, active: isSelected || isDragging),
          radius: isSelected || isDragging ? 8 : 3
        )
        .position(position)
    }
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

  /// Where the pointer is on the day, and nothing more.
  ///
  /// Hollow, against the filled sun: "here is what I am asking about" as
  /// opposed to "here is where we are". Two identical glyphs would be a
  /// question rather than an answer, which is the same reasoning that gave the
  /// sun a moon for the other half of the day.
  ///
  /// **It writes nothing.** Scrubbing reads the schedule and reports what would
  /// be in force; it never applies a stop. A preview that changed the screens
  /// would make examining an evening setting at eleven in the morning cost the
  /// screens being wrong until you stopped looking.
  @ViewBuilder
  private func scrubHead(in size: CGSize) -> some View {
    if let scrubbed, dragging == nil {
      let position = point(at: scrubbed, in: size)

      Rectangle()
        .fill(theme.rim(for: theme.tone))
        .frame(width: 1, height: max(0, size.height - position.y))
        .position(x: position.x, y: (position.y + size.height) / 2)
        .allowsHitTesting(false)

      Circle()
        .strokeBorder(theme.fill(for: theme.tone), lineWidth: 2)
        .frame(width: 13, height: 13)
        .position(position)
        .allowsHitTesting(false)
    }
  }

  private func sun(in size: CGSize) -> some View {
    let position = point(at: nowFraction, in: size)
    // Night is more of the arc than daylight for half the year, and a sun over
    // a dark schedule reads as wrong even when the position is right.
    let isDaytime = nowFraction > 0.25 && nowFraction < 0.8
    let orbTint = isDaytime ? Status.warn : theme.studioAccent

    return ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              orbTint.opacity(0.42),
              orbTint.opacity(0.12),
              .clear,
            ],
            center: .center,
            startRadius: 2,
            endRadius: 20
          )
        )
        .frame(width: 40, height: 40)

      Circle()
        .fill(Color.black.opacity(scheme == .dark ? 0.55 : 0.12))
        .frame(width: 22, height: 22)

      Image(systemName: isDaytime ? "sun.max.fill" : "moon.stars.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isDaytime ? Status.warn : .white)
        .contentTransition(.symbolEffect(.replace))
    }
    .position(position)
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

  /// Which stop is in force at a position on the arc.
  ///
  /// Resolved against the arc's own placement rather than through
  /// `DaySchedule.currentStop(at:solar:)`, and that is deliberate. A sunset stop
  /// is *drawn* at a nominal half past seven and may really fall at ten past
  /// nine; asking the schedule would answer about a moment other than the one
  /// being pointed at, and the picture and the caption under it would disagree.
  /// Pointing at a picture is a question about the picture.
  ///
  /// It wraps: before the day's first stop, the one still in force is the last
  /// of the previous day. Without that the early hours — exactly the part of
  /// the day an evening setting is most likely to still be governing — would
  /// report nothing at all.
  static func stop(at fraction: Double, stops: [ScheduleStop]) -> ScheduleStop? {
    guard !stops.isEmpty else { return nil }
    let placed = stops
      .map { (position: Self.fraction(of: $0, stops: stops), stop: $0) }
      .sorted { $0.position < $1.position }
    return (placed.last { $0.position <= fraction } ?? placed.last)?.stop
  }

  /// The clock time a position on the arc stands for.
  ///
  /// The arc's own coordinate, not a claim about when a solar stop happens —
  /// `label(for:)` is what names those, and it names them "Sunset" rather than
  /// inventing an hour for them.
  static func timeLabel(at fraction: Double) -> String {
    let minutes = Int((min(1, max(0, fraction)) * 24 * 60).rounded())
    return String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
  }

  static func label(for stop: ScheduleStop) -> String {
    switch stop.time {
    case let .clock(hour, minute):
      String(format: "%02d:%02d", hour, minute)
    case let .sunrise(offset):
      offset == 0 ? "Aufgang" : "Aufgang \(offset > 0 ? "+" : "")\(offset) Min"
    case let .sunset(offset):
      offset == 0 ? "Untergang" : "Untergang \(offset > 0 ? "+" : "")\(offset) Min"
    }
  }
}
