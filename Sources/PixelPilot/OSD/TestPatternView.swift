import SwiftUI

/// The pattern itself, edge to edge, with a plate saying what it is.
///
/// Everything here is drawn in `.sRGB` with no opacity and no material. That is
/// not a style choice: a pattern composited through a translucent layer is a
/// measurement of the compositor, and the whole point is to see what the panel
/// does with a known value.
struct TestPatternView: View {
  let pattern: TestPattern
  let displayName: String
  let index: Int
  let total: Int
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onClose: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      content
        .ignoresSafeArea()
        // The whole surface is the "next" target. A test pattern you have to
        // aim at to leave is one you are hunting a button on while trying to
        // look at the pixels.
        .contentShape(Rectangle())
        .onTapGesture(perform: onNext)

      plate
        .padding(Layout.loose)
    }
    .background(Color.black)
  }

  @ViewBuilder
  private var content: some View {
    switch pattern {
    case .white: grey(1.0)
    case .black: grey(0.0)
    case .red: solid(red: 1, green: 0, blue: 0)
    case .green: solid(red: 0, green: 1, blue: 0)
    case .blue: solid(red: 0, green: 0, blue: 1)
    case .greyRamp: ramp
    case .shadowSteps: steps([0.00, 0.01, 0.02, 0.03, 0.04])
    case .highlightSteps: steps([0.96, 0.97, 0.98, 0.99, 1.00])
    case .uniformityMid: grey(0.5)
    case .uniformityDark: grey(0.1)
    case .checkerboard: checkerboard
    }
  }

  private func grey(_ level: Double) -> some View {
    solid(red: level, green: level, blue: level)
  }

  private func solid(red: Double, green: Double, blue: Double) -> some View {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
  }

  /// A continuous sweep rather than a stepped one — the banding being looked
  /// for is the panel's, and drawing our own steps would hand it to you.
  private var ramp: some View {
    LinearGradient(
      stops: (0 ... 64).map { step in
        let level = Double(step) / 64
        return Gradient.Stop(
          color: Color(.sRGB, red: level, green: level, blue: level, opacity: 1),
          location: level
        )
      },
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  /// Full-height bars, so each step touches its neighbour along a long edge.
  /// The eye finds a boundary between two near-identical tones far better than
  /// it judges either one alone.
  private func steps(_ levels: [Double]) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Color(.sRGB, red: level, green: level, blue: level, opacity: 1)
      }
    }
  }

  /// Drawn in device pixels rather than points: on a Retina panel a one-point
  /// checkerboard is a two-pixel one, which tests nothing.
  private var checkerboard: some View {
    Canvas { context, size in
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let side = 1.0 / scale
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
      var y = 0.0
      var row = 0
      while y < size.height {
        var x = row.isMultiple(of: 2) ? 0.0 : side
        while x < size.width {
          context.fill(
            Path(CGRect(x: x, y: y, width: side, height: side)), with: .color(.white)
          )
          x += side * 2
        }
        y += side
        row += 1
      }
    }
  }

  /// Says what is on screen, what to look for, and how to leave.
  ///
  /// Sits in a corner rather than the middle, and is the one thing here that is
  /// allowed to be a material: it is furniture, not part of the measurement.
  private var plate: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text(displayName)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
      Text(pattern.title)
        .font(TypeScale.rowTitle)
      Text(pattern.purpose)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      Divider().padding(.vertical, 2)

      Text("\(index + 1) of \(total) · click or → for the next · ← to go back · esc to leave")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
      Text("Pixel Pilot's own colour tables are off this display while this is up, "
        + "so you're seeing the panel as macOS hands it over.")
        .font(TypeScale.detail)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Layout.normal)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusCard))
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusCard)
        .strokeBorder(.separator, lineWidth: 1)
    }
    // The plate covers pixels, and on a solid-colour pattern those are exactly
    // the pixels being inspected. Holding the pointer over it moves it out of
    // the way rather than making it disappear, so it can always be found again.
    .opacity(isHidden ? 0.08 : 1)
    .onHover { isHidden = $0 }
    .animation(.easeOut(duration: 0.15), value: isHidden)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(pattern.title). \(pattern.purpose)")
  }

  @State private var isHidden = false
}
