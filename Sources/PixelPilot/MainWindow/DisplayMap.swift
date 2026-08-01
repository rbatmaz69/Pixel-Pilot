import AppKit
import PixelPilotCore
import SwiftUI

/// The displays as they are actually arranged on the desk.
///
/// Sits **above** the sidebar list rather than replacing it. The list was
/// chosen deliberately — `MainWindow` documents that a custom stack with a
/// sliding pill would look better and would cost arrow-key navigation of the
/// sidebar — and that trade has not changed. Clicking a rectangle writes the
/// same selection the list does, so keyboard focus never leaves the list and
/// the map is a shortcut rather than a second, competing control.
///
/// A list answers "which displays are there". Only a picture answers "which of
/// them is the one on my left".
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

    return MorphingRoundedRectangle(cornerRadius: 5)
      .fill(theme.wash(for: display.accent))
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
      .overlay {
        AccentDot(accent: display.accent, isReady: display.isReady, size: 7)
      }
      .frame(width: rect.width, height: rect.height)
      // A translation, not a scale: nothing in a tile is dragged, but keeping
      // the same rule everywhere is cheaper than remembering where it applies.
      .offset(x: rect.minX, y: rect.minY - (isHovered && !motion.isReduced ? 2 : 0))
      .animation(motion.spatialFast, value: isHovered)
      .contentShape(.rect)
      .onHover { hovered = $0 ? display.id : (hovered == display.id ? nil : hovered) }
      .onTapGesture { selection = display.id }
      .help(display.name)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityLabel(display.name)
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
