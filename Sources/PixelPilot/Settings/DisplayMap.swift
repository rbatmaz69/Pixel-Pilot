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

    return MorphingRoundedRectangle(cornerRadius: 5)
      .fill(theme.wash(for: display.accent))
      // The level, as a filling rather than as a figure. It is clipped by the
      // shape below rather than being a shape of its own, so a tile's corners
      // stay the tile's corners whatever the level is.
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(theme.fill(for: display.accent).opacity(0.5))
          .frame(height: rect.height * min(1, max(0, display.brightness)))
          // No animation on the height. During a drag this has to be where the
          // pointer put it, for the same reason a slider handle does — and the
          // rest of the time it moves because something else moved it, which is
          // a fact rather than a transition.
          .animation(nil, value: display.brightness)
      }
      .clipShape(MorphingRoundedRectangle(cornerRadius: 5))
      .overlay {
        MorphingRoundedRectangle(cornerRadius: 5)
          .strokeBorder(theme.rim(for: display.accent), lineWidth: 1)
      }
      .overlay {
        if isSelected {
          // One ring for the whole map, so choosing another display makes it
          // travel there rather than blink out here and in again over there —
          // the same idiom as the accent swatches.
          MorphingRoundedRectangle(cornerRadius: 5)
            .strokeBorder(display.accent, lineWidth: 2)
            .matchedGeometryEffect(id: "mapRing", in: ring)
        }
      }
      .overlay { badge(display, isDragging: isDragging) }
      .animation(motion.effectFast, value: isDragging)
      .frame(width: rect.width, height: rect.height)
      // A translation, not a scale: the tile is now dragged, which makes the
      // rule load-bearing here rather than merely consistent — a scale remaps
      // the coordinate space the translation is measured in.
      .offset(x: rect.minX, y: rect.minY - (isHovered && !motion.isReduced ? 2 : 0))
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

  /// The dot, or the figure while the tile is being dragged.
  ///
  /// One or the other rather than both: a tile is forty points across, and the
  /// number is only worth the room it takes while someone is setting it.
  @ViewBuilder
  private func badge(_ display: DisplayViewModel, isDragging: Bool) -> some View {
    if isDragging {
      Text("\(Int((display.brightness * 100).rounded()))%")
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(theme.ink(for: display.accent))
        .transition(.blurReplace)
    } else {
      AccentDot(accent: display.accent, isReady: display.isReady, size: 7)
        .transition(.blurReplace)
    }
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
      spacing: 5
    )
    return Array(zip(displays, rects)).map { ($0, $1) }
  }
}
