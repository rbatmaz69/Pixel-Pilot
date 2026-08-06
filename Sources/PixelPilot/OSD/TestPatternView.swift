import PixelPilotCore
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
  let mode: DisplayHealthController.Mode
  let defects: [PixelDefect]
  let isPlateHidden: Bool
  /// `(step, total)` while a guided check is running.
  let checkProgress: (step: Int, total: Int)?
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onMark: (CGPoint, CGSize, CGFloat) -> Void
  let onMarkRegion: (CGRect, CGSize) -> Void
  let onToggleMarking: () -> Void
  let onTogglePlate: () -> Void
  let onClose: () -> Void

  /// Anything shorter than this is a click. Told apart afterwards by how far
  /// the pointer travelled rather than by two gestures racing — a tap gesture
  /// and a drag gesture on the same surface produce a click that also draws a
  /// zero-size region.
  private static let clickSlop: CGFloat = 4

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        content
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .gesture(surfaceGesture(size: geometry.size))

        if !defects.isEmpty || draft != nil {
          PixelMarkerOverlay(defects: defects, draft: draft, ink: pattern.ink)
        }

        // The plate keeps the pointer in every mode now, including marking,
        // because it holds the buttons that make this workable without the
        // keyboard. The objection that used to make it refuse — a pixel
        // underneath something that swallows clicks can never be marked — is
        // answered by "Hide", which is one click away and puts the whole
        // corner back.
        if isPlateHidden {
          showChip.padding(Layout.loose)
        } else {
          plate
            .padding(Layout.loose)
            .opacity(plateOpacity)
        }
      }
      .background(Color.black)
    }
  }

  /// Click and drag mean different things, and that is what lets marking need
  /// no mode at all.
  ///
  /// **A drag is never "next".** Nobody drags a box across a screen meaning
  /// *show me the following picture*, so dragging one round a bad pixel can
  /// mark it in every mode without ever colliding with what a click does. That
  /// is the whole reason marking is reachable with the mouse alone: the first
  /// version put it behind `M`, which is fine once you know and invisible until
  /// you do.
  ///
  /// **A click still advances**, which is what this overlay has always done and
  /// is worth keeping — a test pattern you have to aim at to advance is one you
  /// are hunting a button on while trying to look at the pixels. Inside mark
  /// mode a click means the spot instead, because there the pointer is being
  /// aimed at something anyway.
  ///
  /// The two are told apart by how far the pointer travelled, not by two
  /// gestures racing: `.simultaneously(with:)` gives a click that also draws a
  /// zero-size region and a drag that also turns the page.
  private func surfaceGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        guard travel(value) >= Self.clickSlop else { return }
        draft = CGRect(from: value.startLocation, to: value.location)
      }
      .onEnded { value in
        defer { draft = nil }
        if travel(value) >= Self.clickSlop {
          onMarkRegion(CGRect(from: value.startLocation, to: value.location), size)
        } else if mode == .marking {
          onMark(value.location, size, scale)
        } else {
          // A click anywhere advances, in browse and during a check alike —
          // during a check that is "looks right", which is the same thing the
          // space bar says.
          onNext()
        }
      }
  }

  private func travel(_ value: DragGesture.Value) -> CGFloat {
    hypot(value.translation.width, value.translation.height)
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

  /// A one-device-pixel checkerboard: two pixels of image, tiled.
  ///
  /// Drawn in device pixels rather than points, because on a Retina panel a
  /// one-*point* checkerboard is a two-pixel one, which tests nothing. The tile
  /// is 2×2 device pixels and is handed to `Image` at the display's scale, so
  /// its natural size is one point and tiling repeats it exactly on the pixel
  /// grid.
  ///
  /// **This used to be a `Canvas` filling one `Path` per pixel, and that is why
  /// it is not any more.** On a 4K panel that is 2160 rows of 1920 squares —
  /// 4.1 million path allocations into a display list that is then retained,
  /// which measured at **1.1 GB for a single render**. Nothing released it, and
  /// every re-render (a hover, a mark, a change of mode) added another
  /// gigabyte; walking the patterns to the end and looking around was enough to
  /// take the machine to tens of gigabytes and force a kill from Activity
  /// Monitor. A tile costs 16 bytes and draws the same picture.
  @ViewBuilder
  private var checkerboard: some View {
    if let tile = Self.checkerTile {
      Image(decorative: tile, scale: scale)
        .resizable(resizingMode: .tile)
        // Belt and braces: there is no scaling here, but a smoothed
        // checkerboard would read as flat grey and quietly turn this into a
        // pattern that always passes.
        .interpolation(.none)
    } else {
      // Never expected. Mid grey rather than nothing, so a failure looks like a
      // failure rather than like a display that scales perfectly.
      Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 1)
    }
  }

  /// Two by two pixels: white, black on the first row, black, white on the
  /// second. Built once — it does not depend on the screen, only the scale it
  /// is handed to `Image` at does.
  private static let checkerTile: CGImage? = {
    let white: [UInt8] = [255, 255, 255, 255]
    let black: [UInt8] = [0, 0, 0, 255]
    let pixels = white + black + black + white

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }

    return CGImage(
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 8,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }()

  /// Says what is on screen, what to look for, and how to leave.
  ///
  /// Sits in a corner rather than the middle, and is the one thing here that is
  /// allowed to be a material: it is furniture, not part of the measurement.
  private var plate: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(spacing: Layout.tight) {
        Text(displayName)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
        if let checkProgress {
          Text("· step \(checkProgress.step) of \(checkProgress.total)")
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
      }
      Text(pattern.title)
        .font(TypeScale.rowTitle)
      Text(pattern.purpose)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      Divider().padding(.vertical, 2)

      Text(keyHint)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      if !defects.isEmpty {
        Text(markSummary)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }

      Text("Pixel Pilot's own colour tables are off this display while this is up, "
        + "so you're seeing the panel as macOS hands it over.")
        .font(TypeScale.detail)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      buttons
        .padding(.top, Layout.hair)
    }
    // Held to the width of its own text. Without this the `Divider` takes every
    // point on offer and the plate spans the whole screen — which was survivable
    // when the only thing under it was a pattern to look at, and is not now that
    // what is under it is pixels somebody is trying to click.
    .frame(width: 320, alignment: .leading)
    .padding(Layout.normal)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusCard))
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusCard)
        .strokeBorder(.separator, lineWidth: 1)
    }
    // The plate covers pixels, and on a solid-colour pattern those are exactly
    // the pixels being inspected. Holding the pointer over it moves it out of
    // the way rather than making it disappear, so it can always be found again.
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(pattern.title). \(pattern.purpose)")
  }

  /// Everything the overlay can do, reachable without touching the keyboard.
  ///
  /// The keys all still work and are still listed above; these exist because a
  /// feature whose only door is a letter key is a feature most people never
  /// find. Marking especially: dragging a box needs no mode at all now, but the
  /// per-pixel work — click to place, click again to remove — does, and there
  /// was no way into it but `M`.
  private var buttons: some View {
    HStack(spacing: Layout.tight) {
      if mode == .marking {
        Button("Done marking", action: onToggleMarking)
          .buttonStyle(.soft)
      } else {
        Button("Mark bad pixels", action: onToggleMarking)
          .buttonStyle(.soft)
      }

      Button("Hide", action: onTogglePlate)
        .buttonStyle(.soft)
        .help("Puts this corner back on the screen so you can see what is under it")

      Button("Close", action: onClose)
        .buttonStyle(.soft)
    }
    .font(TypeScale.detail.weight(.medium))
  }

  /// What is left when the plate is hidden.
  ///
  /// Small, in the same corner, and the only thing on screen that is not the
  /// pattern. Without it, hiding the plate with the mouse would be a one-way
  /// door — the way back was `H`, which is the keyboard again.
  ///
  /// Inked against the pattern rather than styled, and that is not neatness: a
  /// `.soft` button at low opacity is invisible on black, which is exactly the
  /// pattern somebody is most likely to hide the plate on. A door nobody can
  /// see is the door not being there.
  private var showChip: some View {
    Button(action: onTogglePlate) {
      Text("Show controls")
        .font(TypeScale.detail.weight(.medium))
        .padding(.horizontal, Layout.snug)
        .padding(.vertical, Layout.tight)
        .foregroundStyle(chipInk)
        .overlay {
          RoundedRectangle(cornerRadius: Layout.radiusControl)
            .strokeBorder(chipInk, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .opacity(0.55)
  }

  private var chipInk: Color {
    switch pattern.ink {
    case .dark: .black
    case .light: .white
    }
  }

  /// While marking, the plate stays fully legible and Hide is the way to move it
  /// out of the way.
  ///
  /// A first attempt dimmed it to a fixed 0.35 instead, which had it least
  /// readable in the mode where it matters most: what it holds while marking is
  /// how to mark, and the whole feature is unusable without it. So it is
  /// legible by default and gone entirely on one click, rather than permanently
  /// half of both.
  private var plateOpacity: Double {
    switch mode {
    case .marking: 1
    default: isHovered ? 0.08 : 1
    }
  }

  /// Leads with the mouse in every mode, because that is what somebody standing
  /// in front of a screen full of pixels reaches for. The keys follow.
  private var keyHint: String {
    switch mode {
    case .marking:
      "Click a bad pixel to mark it, or drag a box round a patch. "
        + "Click a mark again to remove it · arrows nudge the last one · "
        + "S stuck · D dead · ⌫ removes · esc leaves"
    case .check:
      "Drag a box round anything wrong to mark it. "
        + "Click, space or Y if it looks right · N if something's wrong · "
        + "← to go back · esc to leave"
    default:
      "\(index + 1) of \(total) · drag a box round a bad pixel to mark it · "
        + "click or → for the next · ← to go back · esc to leave"
    }
  }

  private var markSummary: String {
    let summary = PixelDefects.summary(defects)
    return summary.isEmpty ? "\(defects.count) marked" : "Marked here: \(summary)"
  }

  /// The panel's own backing scale. A checkerboard or a mark sized against the
  /// main screen's would be wrong on every display but one.
  @Environment(\.displayScale) private var scale
  @State private var isHovered = false
  @State private var draft: CGRect?
}

extension CGRect {
  /// Two corners in any order into a rectangle. A drag that goes up and to the
  /// left is as valid as one that goes down and to the right, and a negative
  /// width would be neither drawable nor storable.
  init(from start: CGPoint, to end: CGPoint) {
    self.init(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
  }
}
