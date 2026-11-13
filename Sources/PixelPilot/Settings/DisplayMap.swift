import AppKit
import PixelPilotCore
import SwiftUI

/// The displays as they are actually arranged on the desk.
///
/// Sits **above** the sidebar list rather than replacing it. The list was
/// chosen deliberately — `SettingsWindow` documents that a custom stack with a
/// sliding pill would look better and would cost arrow-key navigation of the
/// sidebar — and that trade has not changed. Clicking a rectangle writes the
/// same selection the list does, so keyboard focus never leaves the list and
/// the map is a shortcut rather than a second, competing control.
///
/// A list answers "which displays are there". Only a picture answers "which of
/// them is the one on my left".
///
/// Each screen also fills from the bottom with its own level, and can be
/// dragged. Both fell out of the same observation: the map is the only place in
/// the app that shows the displays next to each other in the shape they
/// actually have, which makes it the only place "that one is darker than the
/// other" is a thing you can see rather than two numbers you have to compare.
/// Once it says that, being able to fix it there is a shorter path than
/// selecting the display and finding the slider.
struct DisplayMap: View {
  let displays: [DisplayViewModel]
  @Binding var selection: DisplayViewModel.ID?
  /// Bumped when screens are added, removed or rearranged, so the geometry is
  /// recomputed then and at no other time.
  let layoutTick: Int

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Namespace private var ring
  @State private var hovered: DisplayViewModel.ID?
  @State private var dragging: DisplayViewModel.ID?
  /// Where the display was when the drag began. Captured once, because the
  /// gesture is relative — see `travel`.
  @State private var dragStart: Double = 0
  /// Latched exactly as `ExpressiveSlider` latches them, so sitting inside a
  /// detent gives one tick rather than one per frame.
  @State private var latchedDetent: Double?
  @State private var isAtEnd = false

  /// How far the pointer travels to cross the whole range, in points.
  ///
  /// The gesture is **relative** because of this number rather than in spite of
  /// it: a tile is around 40 pt tall, so mapping the range onto its height
  /// would make every pixel two and a half per cent and put fine adjustment out
  /// of reach. A fixed travel also means two tiles of different sizes respond
  /// identically, which is what stops the map from feeling like several
  /// controls that happen to look alike.
  private static let travel: Double = 120

  var body: some View {
    GeometryReader { geometry in
      let placed = placements(in: geometry.size)
      ZStack(alignment: .topLeading) {
        ForEach(placed, id: \.display.id) { entry in
          tile(entry.display, in: entry.rect)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }
    .frame(height: 108)
    .animation(motion.spatialDefault, value: selection)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Display arrangement")
  }

  private func tile(_ display: DisplayViewModel, in rect: CGRect) -> some View {
    let isSelected = selection == display.id
    let isHovered = hovered == display.id
    let isDragging = dragging == display.id
    let level = min(1, max(0, display.brightness))
    let screenShape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    return ZStack(alignment: .bottom) {
      // Physical monitor screen bezel + wallpaper + live brightness level
      screenShape
        .fill(Color(.sRGB, red: 0.11, green: 0.095, blue: 0.085))
        .overlay {
          // Warm Studio Horizon mini-wallpaper modulated by live brightness
          StudioWallpaperCanvas(
            accent: display.accent,
            brightness: level,
            isCompact: true
          )
        }
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(theme.fill(for: display.accent).opacity(0.28))
            .frame(height: rect.height * level)
            .animation(nil, value: display.brightness)
        }
        .overlay(alignment: .top) {
          // MacBook camera notch silhouette for built-in displays
          if display.isBuiltin {
            UnevenRoundedRectangle(
              topLeadingRadius: 0,
              bottomLeadingRadius: 2.5,
              bottomTrailingRadius: 2.5,
              topTrailingRadius: 0
            )
            .fill(Color.black.opacity(0.88))
            .frame(width: min(16, rect.width * 0.26), height: 3)
          }
        }
        .clipShape(screenShape)
        .overlay {
          screenShape
            .strokeBorder(
              isSelected ? display.accent : theme.rim(for: display.accent),
              lineWidth: isSelected ? 2 : 1.25
            )
        }
        .overlay {
          if isSelected {
            screenShape
              .strokeBorder(display.accent, lineWidth: 2)
              .matchedGeometryEffect(id: "mapRing", in: ring)
          }
        }
        .overlay { badge(display, isDragging: isDragging) }
        .shadow(
          color: display.accent.opacity(0.14 + 0.36 * level),
          radius: 5 + 9 * level,
          y: 1
        )

      // Physical hardware foot / MacBook base lip silhouette below bezel
      if display.isBuiltin {
        Capsule(style: .continuous)
          .fill(Color.primary.opacity(0.28))
          .frame(width: min(rect.width * 1.08, rect.width + 6), height: 2.5)
          .offset(y: 3.5)
      } else {
        VStack(spacing: 0) {
          Rectangle()
            .fill(Color.primary.opacity(0.24))
            .frame(width: 4, height: 3)
          Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.30))
            .frame(width: min(18, rect.width * 0.36), height: 2)
        }
        .offset(y: 5)
      }
    }
    .animation(motion.effectFast, value: isDragging)
    .frame(width: rect.width, height: rect.height)
    .offset(x: rect.minX, y: rect.minY - (isHovered && !motion.isReduced ? 1 : 0))
    .animation(motion.spatialFast, value: isHovered)
    .contentShape(.rect)
    .onHover { hovered = $0 ? display.id : (hovered == display.id ? nil : hovered) }
    .onTapGesture { selection = display.id }
    .gesture(dragGesture(for: display))
    .help(display.name)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(display.name)
    .accessibilityValue(
      Text(display.brightness, format: .percent.precision(.fractionLength(0)))
    )
    .accessibilityAdjustableAction { direction in
      guard display.isReady else { return }
      let step = 1.0 / 16.0
      display.setBrightness(
        min(1, max(0, display.brightness + (direction == .increment ? step : -step)))
      )
      display.commitBrightness()
    }
  }

  /// Compact glass pill badge inside the mini-monitor showing the warm LED and percentage.
  @ViewBuilder
  private func badge(_ display: DisplayViewModel, isDragging: Bool) -> some View {
    HStack(spacing: 4) {
      AccentDot(accent: display.accent, isReady: display.isReady, size: 6)
      Text("\(Int((display.brightness * 100).rounded()))%")
        .font(.system(size: isDragging ? 10.5 : 9.5, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(
      Capsule(style: .continuous)
        .fill(Color.black.opacity(isDragging ? 0.68 : 0.48))
    )
  }

  // MARK: - Dragging a screen

  /// Four points before this counts as a drag, so a tap still selects.
  ///
  /// A zero-distance drag would swallow the tap the map was built for, and the
  /// picture would stop being a shortcut to the list and start being a rival to
  /// it.
  private func dragGesture(for display: DisplayViewModel) -> some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { gesture in
        guard display.isReady else { return }
        if dragging != display.id {
          dragging = display.id
          dragStart = display.brightness
          // Adjusting a screen is a statement about which one you mean.
          selection = display.id
        }
        adjust(display, by: -Double(gesture.translation.height) / Self.travel)
      }
      .onEnded { _ in
        guard dragging == display.id else { return }
        dragging = nil
        latchedDetent = nil
        isAtEnd = false
        // One verified write per gesture, exactly as `ExpressiveSlider` commits
        // on release rather than on every frame of a drag.
        display.commitBrightness()
      }
  }

  /// Moves the display, and says so through the trackpad.
  ///
  /// The detents come from `SliderDetents` rather than from a second copy of
  /// the same quarters: that file exists because whether a mark is entered once,
  /// at the right place, at a width that feels the same on two differently sized
  /// controls is a matter of fact rather than taste. A map tile is just another
  /// differently sized control.
  private func adjust(_ display: DisplayViewModel, by delta: Double) {
    let level = min(1, max(0, dragStart + delta))

    let reachedEnd = level <= 0 || level >= 1
    if reachedEnd, !isAtEnd { Haptics.endStop() }
    isAtEnd = reachedEnd

    let detent = SliderDetents.nearest(
      to: level,
      among: SliderDetents.quarters,
      tolerance: SliderDetents.tolerance(points: 4, travel: Self.travel)
    )
    if let detent, detent != latchedDetent, !reachedEnd { Haptics.detent() }
    latchedDetent = detent

    display.setBrightness(level)
  }

  /// Recomputed only when the view is laid out or `layoutTick` changes — there
  /// is nothing watching the screens from in here.
  private func placements(in size: CGSize) -> [(display: DisplayViewModel, rect: CGRect)] {
    _ = layoutTick

    let screens = NSScreen.screens
    let frames = displays.map { display in
      screens.first { $0.displayID == display.displayID }?.frame
        // A display the app knows about but AppKit does not is drawn as a
        // placeholder rather than dropped: a map missing a monitor is worse
        // than a map with an approximate one.
        ?? CGRect(x: 0, y: 0, width: 1600, height: 900)
    }
    let rects = DisplayLayout.normalize(
      frames: frames,
      into: CGRect(origin: .zero, size: size),
      spacing: 7
    )
    return Array(zip(displays, rects)).map { ($0, $1) }
  }
}

/// Reusable living studio wallpaper canvas used in `DisplayMap` mini-monitors
/// and the `DisplayPage` Live Studio-Monitor Hero-Card.
///
/// Renders a warm Sonoma/Sequoia-inspired horizon landscape modulated by live
/// brightness, warmth, and paper finish, with zero timers (`0.0% CPU while idle`).
struct StudioWallpaperCanvas: View {
  let accent: Color
  var brightness: Double
  var warmthFraction: Double = 0.5
  var finish: ToneCurve? = nil
  var isCompact: Bool = false

  var body: some View {
    let clampedBrightness = min(1, max(0, brightness))
    let exposure = 0.22 + 0.78 * clampedBrightness
    let warmTint = Color(
      .sRGB,
      red: 1.0,
      green: 0.78 - 0.16 * (1 - warmthFraction),
      blue: 0.55 - 0.30 * (1 - warmthFraction),
      opacity: (1 - warmthFraction) * 0.28
    )

    GeometryReader { geo in
      ZStack {
        // Warm sunset/studio sky gradient
        LinearGradient(
          colors: [
            Color(.sRGB, red: 0.18, green: 0.20, blue: 0.34).blended(with: accent, by: 0.28),
            Color(.sRGB, red: 0.76, green: 0.42, blue: 0.24).blended(with: accent, by: 0.22),
            Color(.sRGB, red: 0.95, green: 0.68, blue: 0.36),
          ],
          startPoint: .top,
          endPoint: .bottom
        )

        // Glowing horizon sun orb
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color(.sRGB, red: 1.0, green: 0.94, blue: 0.78, opacity: 0.92),
                Color(.sRGB, red: 0.98, green: 0.64, blue: 0.28, opacity: 0.45),
                .clear,
              ],
              center: .center,
              startRadius: 0,
              endRadius: isCompact ? 18 : 42
            )
          )
          .frame(width: isCompact ? 36 : 84, height: isCompact ? 36 : 84)
          .offset(x: geo.size.width * 0.14, y: -geo.size.height * 0.06)

        // Layered warm studio hills at bottom
        Path { path in
          let w = geo.size.width
          let h = geo.size.height
          path.move(to: CGPoint(x: 0, y: h * 0.72))
          path.addQuadCurve(
            to: CGPoint(x: w * 0.58, y: h * 0.68),
            control: CGPoint(x: w * 0.28, y: h * 0.54)
          )
          path.addQuadCurve(
            to: CGPoint(x: w, y: h * 0.64),
            control: CGPoint(x: w * 0.82, y: h * 0.76)
          )
          path.addLine(to: CGPoint(x: w, y: h))
          path.addLine(to: CGPoint(x: 0, y: h))
          path.closeSubpath()
        }
        .fill(
          LinearGradient(
            colors: [
              Color(.sRGB, red: 0.22, green: 0.15, blue: 0.14),
              Color(.sRGB, red: 0.12, green: 0.09, blue: 0.08),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )

        // Kelvin warmth veil
        Rectangle()
          .fill(warmTint)

        // Paper Finish matte lift simulation
        if let finish {
          Rectangle()
            .fill(Color(.sRGB, red: 0.96, green: 0.93, blue: 0.87, opacity: finish.blackLift * 1.4))
        }

        // Brightness exposure veil
        Rectangle()
          .fill(Color.black.opacity(1 - exposure))
      }
    }
    .allowsHitTesting(false)
  }
}
