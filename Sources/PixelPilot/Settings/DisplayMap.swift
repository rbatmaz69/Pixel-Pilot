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
  enum Mode: Hashable {
    case light
    case arrange
  }

  let displays: [DisplayViewModel]
  @Binding var selection: DisplayViewModel.ID?
  /// Bumped when screens are added, removed or rearranged, so the geometry is
  /// recomputed then and at no other time.
  let layoutTick: Int
  var supportsArrangement: Bool = false
  var onBeginHighlight: ((DisplayViewModel) -> Void)? = nil
  var onEndHighlight: (() -> Void)? = nil
  var onApplyArrangement: (([DisplayLayout.ArrangementEntry]) -> Void)? = nil

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Namespace private var ring
  @State private var mode: Mode = .light
  @State private var hovered: DisplayViewModel.ID?
  @State private var dragging: DisplayViewModel.ID?
  /// Where the display was when the drag began. Captured once, because the
  /// gesture is relative — see `travel`.
  @State private var dragStart: Double = 0
  /// Latched exactly as `ExpressiveSlider` latches them, so sitting inside a
  /// detent gives one tick rather than one per frame.
  @State private var latchedDetent: Double?
  @State private var isAtEnd = false

  // Interactive 2D arrange state
  @State private var arrangeSnapshot: [DisplayLayout.ArrangementEntry]?
  @State private var arrangeDragOriginalFrame: CGRect = .zero
  @State private var arrangeDragPrimaryID: CGDirectDisplayID?
  @State private var arrangeLockedViewport: (desktop: CGRect, scale: CGFloat)?
  @State private var arrangeGuides: [DisplayLayout.AlignmentGuide] = []
  @State private var draggingMenuBarFrom: CGDirectDisplayID?
  @State private var menuBarDropTarget: DisplayViewModel.ID?
  @State private var menuBarDragPoint: CGPoint?

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
    VStack(spacing: 8) {
      if supportsArrangement, displays.count > 1 {
        SegmentedMorphPicker(
          selection: $mode,
          options: [
            (Mode.light, "☀︎ Licht"),
            (Mode.arrange, "↔︎ Anordnen"),
          ],
          accent: theme.tone
        )
        .controlSize(.small)
      }

      GeometryReader { geometry in
        let entries = resolvedEntries
        let placements = placements(for: entries, in: geometry.size)
        let primaryID = primaryDisplayID(in: entries)

        ZStack(alignment: .topLeading) {
          if mode == .arrange {
            alignmentGuideOverlay(for: entries, in: geometry.size)
          }

          ForEach(placements, id: \.display.id) { entry in
            tile(
              entry.display,
              in: entry.rect,
              allPlacements: placements,
              allEntries: entries,
              canvasSize: geometry.size,
              isPrimary: entry.display.displayID == primaryID
            )
          }

          if mode == .arrange, let menuBarDragPoint {
            menuBarPill(isDragging: true)
              .position(menuBarDragPoint)
              .allowsHitTesting(false)
              .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      }
      .frame(height: mode == .arrange ? 148 : 112)
      .animation(dragging == nil ? motion.spatialDefault : nil, value: selection)
      .animation(dragging == nil ? motion.spatialDefault : nil, value: arrangeSnapshot)
      .animation(motion.effectFast, value: mode)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Display-Anordnung")

      if mode == .arrange, supportsArrangement, displays.count > 1 {
        let entries = resolvedEntries
        let primaryID = primaryDisplayID(in: entries)
        let primaryDisplay = displays.first { $0.displayID == primaryID }

        VStack(spacing: 5) {
          Menu {
            ForEach(displays) { display in
              Button {
                let reassigned = DisplayLayout.assignPrimary(id: display.displayID, in: entries)
                onApplyArrangement?(reassigned)
                Haptics.confirm()
              } label: {
                HStack {
                  Text(display.name)
                  if display.displayID == primaryID {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "menubar.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.studioAccent)
              Text("Hauptdisplay:")
                .foregroundStyle(.secondary)
              Text(primaryDisplay?.name ?? "Auswählen")
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 2)
              Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .font(TypeScale.detail)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
          }
          .menuStyle(.borderlessButton)
          .help("Legt fest, welcher Bildschirm die macOS-Menüleiste und Dock-Basis erhält")

          Text("Monitor ziehen · ⌥ ohne Einrasten")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var resolvedEntries: [DisplayLayout.ArrangementEntry] {
    if let arrangeSnapshot { return arrangeSnapshot }
    _ = layoutTick
    if mode == .arrange {
      return displays.map { display in
        DisplayLayout.ArrangementEntry(
          id: display.displayID,
          frame: CGDisplayBounds(display.displayID)
        )
      }
    }
    let screens = NSScreen.screens
    return displays.map { display in
      let frame = screens.first { $0.displayID == display.displayID }?.frame
        ?? CGRect(x: 0, y: 0, width: 1600, height: 900)
      return DisplayLayout.ArrangementEntry(id: display.displayID, frame: frame)
    }
  }

  private func primaryDisplayID(in entries: [DisplayLayout.ArrangementEntry]) -> CGDirectDisplayID? {
    entries.first { abs($0.frame.minX) < 1 && abs($0.frame.minY) < 1 }?.id ?? entries.first?.id
  }

  private func tile(
    _ display: DisplayViewModel,
    in rect: CGRect,
    allPlacements: [(display: DisplayViewModel, rect: CGRect)],
    allEntries: [DisplayLayout.ArrangementEntry],
    canvasSize: CGSize,
    isPrimary: Bool
  ) -> some View {
    let isSelected = selection == display.id
    let isHovered = hovered == display.id
    let isDragging = dragging == display.id

    return ZStack(alignment: .bottom) {
      tileScreen(
        display,
        in: rect,
        allPlacements: allPlacements,
        allEntries: allEntries,
        isPrimary: isPrimary
      )
      tileStand(display, width: rect.width)
    }
    .scaleEffect(isDragging && mode == .arrange ? 1.04 : 1.0)
    .animation(motion.effectFast, value: isDragging)
    .frame(width: rect.width, height: rect.height)
    .offset(x: rect.minX, y: rect.minY - (isHovered && !motion.isReduced && mode == .light ? 1 : 0))
    .animation(dragging == nil ? motion.spatialFast : nil, value: isHovered)
    .contentShape(.rect)
    .onHover { entering in
      hovered = entering ? display.id : (hovered == display.id ? nil : hovered)
      if mode == .arrange {
        if entering {
          NSCursor.openHand.set()
        } else if dragging == nil {
          NSCursor.arrow.set()
        }
      }
    }
    .onTapGesture { selection = display.id }
    .gesture(
      mode == .light
        ? AnyGesture(dragGesture(for: display).map { _ in () })
        : AnyGesture(arrangeGesture(for: display, in: canvasSize, entries: allEntries).map { _ in () })
    )
    .help(mode == .arrange ? "\(display.name) ziehen zum Anordnen" : display.name)
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

  private func tileScreen(
    _ display: DisplayViewModel,
    in rect: CGRect,
    allPlacements: [(display: DisplayViewModel, rect: CGRect)],
    allEntries: [DisplayLayout.ArrangementEntry],
    isPrimary: Bool
  ) -> some View {
    let isSelected = selection == display.id
    let isDragging = dragging == display.id
    let isDropTarget = menuBarDropTarget == display.id
    let level = min(1, max(0, display.brightness))
    let screenShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let span = ColorTemperature.range.upperBound - ColorTemperature.range.lowerBound
    let warmth: Double = display.colorTemperatureKelvin.map { kelvin in
      span > 0 ? min(1, max(0, (kelvin - ColorTemperature.range.lowerBound) / span)) : 1
    } ?? 1.0
    let strokeColor: Color = isDropTarget
      ? theme.studioAccent
      : (isSelected ? display.accent : theme.rim(for: display.accent))
    let strokeWidth: CGFloat = (isDropTarget || isSelected) ? 2 : 1.25
    let shadowColor = display.accent.opacity(isDragging ? 0.55 : (0.14 + 0.36 * level))
    let shadowRadius: CGFloat = isDragging ? 14 : (5 + 9 * level)

    return ZStack {
      Color(.sRGB, red: 0.11, green: 0.095, blue: 0.085)

      StudioWallpaperCanvas(
        displayID: display.displayID,
        accent: display.accent,
        brightness: level,
        warmthFraction: warmth,
        finish: display.toneCurve,
        isCompact: true
      )

      if mode == .light {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle()
            .fill(theme.fill(for: display.accent).opacity(0.28))
            .frame(height: rect.height * level)
            .animation(nil, value: display.brightness)
        }
      }

      VStack(spacing: 0) {
        tileTopChrome(
          display,
          in: rect,
          allPlacements: allPlacements,
          allEntries: allEntries,
          isPrimary: isPrimary
        )
        Spacer(minLength: 0)
      }
    }
    .clipShape(screenShape)
    .overlay(screenShape.strokeBorder(strokeColor, lineWidth: strokeWidth))
    .overlay {
      if isSelected, !isDropTarget {
        screenShape
          .strokeBorder(display.accent, lineWidth: 2)
          .matchedGeometryEffect(id: "mapRing", in: ring)
      }
    }
    .overlay { badge(display, isDragging: isDragging, isPrimary: isPrimary) }
    .shadow(color: shadowColor, radius: shadowRadius, y: 1)
  }

  @ViewBuilder
  private func tileTopChrome(
    _ display: DisplayViewModel,
    in rect: CGRect,
    allPlacements: [(display: DisplayViewModel, rect: CGRect)],
    allEntries: [DisplayLayout.ArrangementEntry],
    isPrimary: Bool
  ) -> some View {
    if isPrimary {
      let pill = menuBarPill(isDragging: false)
        .opacity(draggingMenuBarFrom == display.displayID ? 0.25 : 1)
        .padding(.horizontal, 4)
        .padding(.top, 3)
        .help(mode == .arrange ? "Menüleiste ziehen, um Hauptbildschirm festzulegen" : "Hauptbildschirm")

      if mode == .arrange {
        pill.gesture(
          menuBarDragGesture(
            from: display.displayID,
            tileOrigin: rect.origin,
            tileWidth: rect.width,
            allPlacements: allPlacements,
            allEntries: allEntries
          )
        )
      } else {
        pill
      }
    } else if display.isBuiltin {
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

  @ViewBuilder
  private func tileStand(_ display: DisplayViewModel, width: CGFloat) -> some View {
    if display.isBuiltin {
      Capsule(style: .continuous)
        .fill(Color.primary.opacity(0.28))
        .frame(width: min(width * 1.08, width + 6), height: 2.5)
        .offset(y: 3.5)
    } else {
      VStack(spacing: 0) {
        Rectangle()
          .fill(Color.primary.opacity(0.24))
          .frame(width: 4, height: 3)
        Capsule(style: .continuous)
          .fill(Color.primary.opacity(0.30))
          .frame(width: min(18, width * 0.36), height: 2)
      }
      .offset(y: 5)
    }
  }

  private func badge(_ display: DisplayViewModel, isDragging: Bool, isPrimary: Bool) -> some View {
    HStack(spacing: 4) {
      AccentDot(accent: display.accent, isReady: display.isReady, size: 6)
      if mode == .arrange {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
          .font(.system(size: isDragging ? 10 : 9, weight: .semibold))
          .foregroundStyle(.white)
        if isPrimary {
          Text("Haupt")
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
        }
      } else {
        Text("\(Int((display.brightness * 100).rounded()))%")
          .font(.system(size: isDragging ? 10.5 : 9.5, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(
      Capsule(style: .continuous)
        .fill(Color.black.opacity(isDragging ? 0.72 : 0.48))
    )
  }

  private func menuBarPill(isDragging: Bool) -> some View {
    HStack(spacing: 2) {
      Capsule(style: .continuous)
        .fill(Color.white.opacity(0.95))
        .frame(height: 3.5)
        .overlay {
          if mode == .arrange {
            HStack(spacing: 2) {
              ForEach(0 ..< 3, id: \.self) { _ in
                Circle()
                  .fill(Color.black.opacity(0.45))
                  .frame(width: 1.5, height: 1.5)
              }
            }
          }
        }
    }
    .frame(width: isDragging ? 38 : nil)
    .padding(.vertical, isDragging ? 4 : 2)
  }

  private func viewport(
    for entries: [DisplayLayout.ArrangementEntry],
    in size: CGSize
  ) -> (desktop: CGRect, scale: CGFloat, originX: CGFloat, originY: CGFloat)? {
    let box = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
    guard box.width > 0, box.height > 0 else { return nil }
    let frames = entries.map(\.frame)
    guard let first = frames.first else { return nil }

    let desktop: CGRect
    let scale: CGFloat
    if let locked = arrangeLockedViewport {
      desktop = locked.desktop
      scale = locked.scale
    } else {
      desktop = frames.dropFirst().reduce(first) { $0.union($1) }
      scale = DisplayLayout.scaleFactor(frames: frames, into: box)
    }

    let scaled = CGSize(width: desktop.width * scale, height: desktop.height * scale)
    let originX = box.minX + (box.width - scaled.width) / 2
    let originY = box.minY + (box.height - scaled.height) / 2
    return (desktop, scale, originX, originY)
  }

  @ViewBuilder
  private func alignmentGuideOverlay(
    for entries: [DisplayLayout.ArrangementEntry],
    in size: CGSize
  ) -> some View {
    if let vp = viewport(for: entries, in: size) {
      ForEach(arrangeGuides, id: \.self) { guide in
        Path { path in
          switch guide.axis {
          case .horizontal:
            let y = vp.originY + (guide.position - vp.desktop.minY) * vp.scale
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
          case .vertical:
            let x = vp.originX + (guide.position - vp.desktop.minX) * vp.scale
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
          }
        }
        .stroke(
          theme.studioAccent.opacity(0.9),
          style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
      }
    }
  }

  // MARK: - 2D Arrange Gesture

  private func arrangeGesture(
    for display: DisplayViewModel,
    in canvasSize: CGSize,
    entries: [DisplayLayout.ArrangementEntry]
  ) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { gesture in
        if dragging != display.id {
          dragging = display.id
          selection = display.id
          NSCursor.closedHand.set()
          let initial = entries
          arrangeSnapshot = initial
          arrangeDragPrimaryID = primaryDisplayID(in: initial)
          arrangeDragOriginalFrame = initial.first { $0.id == display.displayID }?.frame
            ?? CGDisplayBounds(display.displayID)
          let box = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 10, dy: 10)
          let initialFrames = initial.map(\.frame)
          if let first = initialFrames.first, box.width > 0, box.height > 0 {
            let desktop = initialFrames.dropFirst().reduce(first) { $0.union($1) }
            let scale = max(0.01, DisplayLayout.scaleFactor(frames: initialFrames, into: box))
            arrangeLockedViewport = (desktop, scale)
          }
          onBeginHighlight?(display)
        }

        let currentEntries = arrangeSnapshot ?? entries
        let box = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 10, dy: 10)
        let scale = arrangeLockedViewport?.scale
          ?? max(0.01, DisplayLayout.scaleFactor(frames: currentEntries.map(\.frame), into: box))
        let freeMove = NSEvent.modifierFlags.contains(.option)
        let threshold: CGFloat = freeMove ? 0 : max(14, 5 / scale)

        let rawMoving = arrangeDragOriginalFrame.offsetBy(
          dx: gesture.translation.width / scale,
          dy: gesture.translation.height / scale
        )
        let stationary = currentEntries
          .filter { $0.id != display.displayID }
          .map(\.frame)

        let snapped = DisplayLayout.snap(
          moving: rawMoving,
          against: stationary,
          threshold: threshold
        )
        if snapped.guides != arrangeGuides, !snapped.guides.isEmpty, !freeMove {
          Haptics.detent()
        }
        arrangeGuides = freeMove ? [] : snapped.guides

        arrangeSnapshot = currentEntries.map { entry in
          guard entry.id == display.displayID else { return entry }
          return DisplayLayout.ArrangementEntry(id: entry.id, frame: snapped.frame)
        }
      }
      .onEnded { _ in
        guard dragging == display.id else { return }
        dragging = nil
        if hovered != nil {
          NSCursor.openHand.set()
        } else {
          NSCursor.arrow.set()
        }
        let committed = arrangeSnapshot
        let preservedPrimary = arrangeDragPrimaryID
        arrangeSnapshot = nil
        arrangeDragPrimaryID = nil
        arrangeLockedViewport = nil
        arrangeGuides = []
        onEndHighlight?()
        if let committed {
          let normalized = preservedPrimary.map {
            DisplayLayout.assignPrimary(id: $0, in: committed)
          } ?? committed
          onApplyArrangement?(normalized)
          Haptics.confirm()
        }
      }
  }

  private func menuBarDragGesture(
    from sourceID: CGDirectDisplayID,
    tileOrigin: CGPoint,
    tileWidth: CGFloat,
    allPlacements: [(display: DisplayViewModel, rect: CGRect)],
    allEntries: [DisplayLayout.ArrangementEntry]
  ) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .local)
      .onChanged { gesture in
        draggingMenuBarFrom = sourceID
        let globalPoint = CGPoint(
          x: tileOrigin.x + tileWidth / 2 + gesture.translation.width,
          y: tileOrigin.y + 6 + gesture.translation.height
        )
        menuBarDragPoint = globalPoint
        let target = allPlacements.first { $0.rect.insetBy(dx: -4, dy: -4).contains(globalPoint) }
        if target?.display.id != menuBarDropTarget {
          menuBarDropTarget = target?.display.id
          if menuBarDropTarget != nil { Haptics.detent() }
        }
      }
      .onEnded { _ in
        let dropID = menuBarDropTarget
        draggingMenuBarFrom = nil
        menuBarDragPoint = nil
        menuBarDropTarget = nil
        guard let dropID,
              let targetDisplay = displays.first(where: { $0.id == dropID }),
              targetDisplay.displayID != sourceID else { return }
        let reassigned = DisplayLayout.assignPrimary(id: targetDisplay.displayID, in: allEntries)
        onApplyArrangement?(reassigned)
        Haptics.confirm()
      }
  }

  // MARK: - Dragging a screen (Brightness mode)

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
  private func placements(
    for entries: [DisplayLayout.ArrangementEntry],
    in size: CGSize
  ) -> [(display: DisplayViewModel, rect: CGRect)] {
    let frames = entries.map(\.frame)
    let rects: [CGRect]
    if mode == .arrange {
      if arrangeLockedViewport != nil, let vp = viewport(for: entries, in: size) {
        rects = frames.map { frame in
          CGRect(
            x: vp.originX + (frame.minX - vp.desktop.minX) * vp.scale,
            y: vp.originY + (frame.minY - vp.desktop.minY) * vp.scale,
            width: max(20, frame.width * vp.scale - 2),
            height: max(14, frame.height * vp.scale - 2)
          )
        }
      } else {
        rects = DisplayLayout.normalizeTopDown(
          frames: frames,
          into: CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10),
          spacing: 2
        )
      }
    } else {
      rects = DisplayLayout.normalize(
        frames: frames,
        into: CGRect(origin: .zero, size: size),
        spacing: 7
      )
    }
    return Array(zip(displays, rects)).map { ($0, $1) }
  }
}

/// Reusable living studio wallpaper canvas used in `DisplayMap` mini-monitors
/// and the `DisplayPage` Live Studio-Monitor Hero-Card.
///
/// Renders the user's cached macOS desktop wallpaper thumbnail (via `WallpaperCache`,
/// falling back gracefully to a Sonoma/Sequoia warm studio horizon when unavailable),
/// modulated by live brightness, warmth, and paper finish with `0.0% idle CPU`.
struct StudioWallpaperCanvas: View {
  var displayID: CGDirectDisplayID? = nil
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
        if let displayID, let nsImage = WallpaperCache.shared.thumbnail(for: displayID) {
          Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        } else {
          studioHorizonArtwork(in: geo.size)
        }

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

  private func studioHorizonArtwork(in size: CGSize) -> some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(.sRGB, red: 0.18, green: 0.20, blue: 0.34).blended(with: accent, by: 0.28),
          Color(.sRGB, red: 0.76, green: 0.42, blue: 0.24).blended(with: accent, by: 0.22),
          Color(.sRGB, red: 0.95, green: 0.68, blue: 0.36),
        ],
        startPoint: .top,
        endPoint: .bottom
      )

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
        .offset(x: size.width * 0.14, y: -size.height * 0.06)

      Path { path in
        let w = size.width
        let h = size.height
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
    }
  }
}
