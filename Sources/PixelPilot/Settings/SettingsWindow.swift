import PixelPilotCore
import SwiftUI

/// Which page the settings window is showing.
///
/// Two kinds, because they are found two different ways: the display pages come
/// from whatever is plugged in right now, and the rest are fixed. `remembered`
/// belongs with the first group and is written like the second, since it is
/// about displays that are *not* connected and so cannot be one of them.
enum SettingsRoute: Hashable {
  case display(DisplayViewModel.ID)
  case remembered
  case app(AppPage)
}

/// The pages that are about the application rather than about one monitor.
///
/// Each carries its own title, symbol and one-line summary, so the sidebar and
/// the window title read from the same place. The summary is not decoration:
/// it is the difference between a list of six words and a list that says what
/// is behind each of them without being opened.
enum AppPage: String, CaseIterable, Hashable {
  case general, updates, keys, presets, schedule, apps, shortcuts

  var title: String {
    switch self {
    case .general: "Allgemein"
    case .updates: "Updates"
    case .keys: "Tasten & Fokus"
    case .presets: "Licht-Szenen"
    case .schedule: "Zeitplan"
    case .apps: "App-Regeln"
    case .shortcuts: "Kurzbefehle"
    }
  }

  var summary: String {
    switch self {
    case .general: "Studio-Stil, Akzentfarbe & Autostart"
    case .updates: "Neue Versionen & Release Notes"
    case .keys: "Medientasten, Rechte & Fokus-Dimmung"
    case .presets: "Gespeicherte Licht- & Ton-Szenen"
    case .schedule: "Automatischer Tagesverlauf"
    case .apps: "Szenen pro Anwendung"
    case .shortcuts: "Globale Tastenkürzel"
    }
  }

  var symbolName: String {
    switch self {
    case .general: "paintpalette"
    case .updates: "arrow.trianglehead.2.clockwise.rotate.90"
    case .keys: "keyboard"
    case .presets: "square.stack"
    case .schedule: "sun.horizon"
    case .apps: "app.badge"
    case .shortcuts: "command"
    }
  }

  /// Warm category badge tint for the 20×20pt rounded-square sidebar icon.
  var badgeTint: Color {
    switch self {
    case .general: Color(.sRGB, red: 0.851, green: 0.420, blue: 0.122)
    case .schedule: Color(.sRGB, red: 0.918, green: 0.545, blue: 0.165)
    case .presets: Color(.sRGB, red: 0.784, green: 0.365, blue: 0.275)
    case .apps: Color(.sRGB, red: 0.255, green: 0.525, blue: 0.745)
    case .shortcuts: Color(.sRGB, red: 0.545, green: 0.392, blue: 0.725)
    case .keys: Color(.sRGB, red: 0.275, green: 0.588, blue: 0.471)
    case .updates: Color(.sRGB, red: 0.392, green: 0.545, blue: 0.647)
    }
  }
}

/// Where the settings window is, kept outside the window.
///
/// `WindowCoordinator` drops a window's whole SwiftUI hierarchy when it closes,
/// which would take a `@State` selection with it. Two things want this to
/// survive: reopening the window should land where it was left, and a caller
/// that has a particular page in mind — dropping an application on the menu bar
/// icon means Apps — has to be able to say so while the window is already open.
@MainActor
@Observable
final class SettingsRouter {
  var route: SettingsRoute = .app(.general)

  /// A display was unplugged or replaced; do not leave a dead selection.
  ///
  /// Only ever moves off a display page, and only when that display has gone.
  /// Somebody reading the schedule while a monitor is unplugged should not be
  /// thrown somewhere else by it.
  func repair(against ids: [DisplayViewModel.ID]) {
    guard case let .display(id) = route, !ids.contains(id) else { return }
    // Remembered rather than a page from the App section: whatever was being
    // looked at was about displays, and that page lists the one that just left.
    route = ids.first.map(SettingsRoute.display) ?? .remembered
  }

  /// Ordered top-to-bottom sidebar routes matching `SettingsWindow`'s list.
  static func orderedRoutes(displayIDs: [DisplayViewModel.ID]) -> [SettingsRoute] {
    displayIDs.map(SettingsRoute.display)
      + [.remembered]
      + AppPage.allCases.map(SettingsRoute.app)
  }

  /// Monotonic top-to-bottom order of sidebar routes for directional page transitions.
  static func routeOrderIndex(
    for route: SettingsRoute,
    displayIDs: [DisplayViewModel.ID]
  ) -> Int {
    orderedRoutes(displayIDs: displayIDs).firstIndex(of: route) ?? 0
  }

  /// Moves selection up (`-1`) or down (`+1`) across the ordered sidebar routes.
  func stepRoute(by delta: Int, displayIDs: [DisplayViewModel.ID]) {
    let routes = Self.orderedRoutes(displayIDs: displayIDs)
    guard !routes.isEmpty else { return }
    guard let currentIndex = routes.firstIndex(of: route) else {
      route = routes[0]
      return
    }
    let nextIndex = min(max(0, currentIndex + delta), routes.count - 1)
    route = routes[nextIndex]
  }
}

/// Every setting in the application, in one window.
///
/// This was two windows: a "Displays" one with the per-monitor controls and
/// configuration, and a "Settings" one with everything else. The split was not
/// a line anybody could hold in their head — the brightness strategy and the
/// DDC timing are settings by any reading, and the accent colour existed in
/// both places at once — so the theme card had to end a paragraph with "that
/// one is in the Displays window", which is a footnote admitting the navigation
/// is wrong.
///
/// One sidebar, two sections: the monitors that are plugged in, then the app
/// itself. Every row carries a line saying what it holds, so finding a setting
/// is reading rather than opening things to check.
struct SettingsWindow: View {
  let model: AppModel
  let router: SettingsRouter

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var navigationDirection: Int = 1
  @Namespace private var sidebarSelectionNamespace

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      ZStack {
        page
          .id(router.route)
          .transition(pageTransition)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(motion.spatialDefault, value: router.route)
    }
    .onAppear { router.repair(against: model.displays.map(\.id)) }
    .onChange(of: model.displays.map(\.id)) { _, ids in
      router.repair(against: ids)
    }
    .onChange(of: router.route) { oldRoute, newRoute in
      let ids = model.displays.map(\.id)
      let oldIndex = SettingsRouter.routeOrderIndex(for: oldRoute, displayIDs: ids)
      let newIndex = SettingsRouter.routeOrderIndex(for: newRoute, displayIDs: ids)
      navigationDirection = newIndex >= oldIndex ? 1 : -1
    }
  }

  private var pageTransition: AnyTransition {
    if motion.isReduced { return .opacity }
    return .asymmetric(
      insertion: .offset(y: CGFloat(navigationDirection) * 10).combined(with: .opacity),
      removal: .offset(y: CGFloat(-navigationDirection) * 8).combined(with: .opacity)
    )
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    // Still a `List` with a system selection rather than a custom stack with
    // a sliding pill. The pill would look better and would cost arrow-key
    // navigation of the sidebar, which is not a trade worth making for a
    // highlight.
    VStack(spacing: 0) {
      if model.displays.count > 1 {
        // Only with more than one. A map of a single display is a rectangle
        // saying what the row below it already says.
        DisplayMap(
          displays: model.displays,
          selection: mapSelection,
          layoutTick: model.screenLayoutTick,
          supportsArrangement: true,
          onBeginHighlight: { model.beginArrangingHighlight(for: $0) },
          onEndHighlight: { model.endArrangingHighlight() },
          onApplyArrangement: { model.applyDisplayArrangement($0) }
        )
        .padding(.horizontal, Layout.snug)
        .padding(.top, Layout.snug)

        Button {
          model.identifyDisplays()
        } label: {
          Label("Identifizieren", systemImage: "number.circle")
            .font(TypeScale.detail.weight(.medium))
        }
        .buttonStyle(.soft)
        .padding(.vertical, Layout.tight)
      }

      ScrollViewReader { scrollProxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Layout.tight) {
            sidebarSectionHeader("Displays")

            VStack(alignment: .leading, spacing: 2) {
              ForEach(model.displays) { display in
                let route = SettingsRoute.display(display.id)
                let isSelected = router.route == route
                SidebarItemButton(
                  isSelected: isSelected,
                  accent: display.accent,
                  namespace: sidebarSelectionNamespace,
                  action: { router.route = route }
                ) { isHovered in
                  SidebarRow(
                    title: display.name,
                    summary: display.isBuiltin ? "Integriert" : display.routeDescription,
                    trailingText: "\(Int((display.brightness * 100).rounded()))%",
                    isSelected: isSelected,
                    isHovered: isHovered
                  ) { hovered in
                    displayLeadingBadge(display: display, isHovered: hovered)
                  }
                }
                .id(route)
              }

              let rememberedSelected = router.route == .remembered
              SidebarItemButton(
                isSelected: rememberedSelected,
                accent: theme.studioAccent,
                namespace: sidebarSelectionNamespace,
                action: { router.route = .remembered }
              ) { isHovered in
                SidebarRow(
                  title: "Bekannte Displays",
                  summary: "Früher verbundene Monitore",
                  symbolName: "externaldrive.badge.checkmark",
                  isSelected: rememberedSelected,
                  isHovered: isHovered
                )
              }
              .id(SettingsRoute.remembered)
            }

            sidebarSectionHeader("Studio")
              .padding(.top, Layout.tight)

            VStack(alignment: .leading, spacing: 2) {
              ForEach(AppPage.allCases, id: \.self) { app in
                let route = SettingsRoute.app(app)
                let isSelected = router.route == route
                SidebarItemButton(
                  isSelected: isSelected,
                  accent: theme.studioAccent,
                  namespace: sidebarSelectionNamespace,
                  action: { router.route = route }
                ) { isHovered in
                  SidebarRow(
                    title: app.title,
                    summary: app.summary,
                    symbolName: app.symbolName,
                    tint: app.badgeTint,
                    isSelected: isSelected,
                    isHovered: isHovered
                  )
                }
                .id(route)
              }
            }
          }
          .padding(.horizontal, Layout.snug)
          .padding(.vertical, Layout.tight)
        }
        .onChange(of: router.route) { _, newRoute in
          withAnimation(motion.spatialFast) {
            scrollProxy.scrollTo(newRoute, anchor: .center)
          }
        }
      }
      .focusable()
      .focusEffectDisabled()
      .onKeyPress(.upArrow) {
        router.stepRoute(by: -1, displayIDs: model.displays.map(\.id))
        return .handled
      }
      .onKeyPress(.downArrow) {
        router.stepRoute(by: 1, displayIDs: model.displays.map(\.id))
        return .handled
      }
      .animation(motion.tactileSnap ?? motion.spatialDefault, value: router.route)
      .animation(motion.spatialDefault, value: model.displays.map(\.id))

      Divider()
      sidebarFooter
    }
    .background {
      theme.sidebarSurface
        .ignoresSafeArea()
    }
    .background(alignment: .top) {
      theme.ambientDaylightGradient()
        .frame(height: 120)
        .allowsHitTesting(false)
    }
    .navigationSplitViewColumnWidth(min: 245, ideal: 265)
  }

  private func sidebarSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(theme.secondaryInk)
      .padding(.horizontal, 8)
      .padding(.top, 4)
      .padding(.bottom, 2)
  }

  private func displayLeadingBadge(display: DisplayViewModel, isHovered: Bool) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
        .fill(theme.wash(for: display.accent))
        .overlay {
          RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
            .strokeBorder(theme.rim(for: display.accent).opacity(0.45), lineWidth: 0.75)
        }
        .frame(width: 20, height: 20)

      AccentDot(accent: display.accent, isReady: display.isReady, size: 8)
    }
    .scaleEffect(isHovered && !motion.isReduced ? 1.08 : 1.0)
    .animation(motion.spatialFast, value: isHovered)
  }

  private var sidebarFooter: some View {
    HStack(spacing: 6) {
      AccentDot(accent: Status.ok, size: 6)
      Text("0,0 % CPU im Leerlauf")
        .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundStyle(theme.secondaryInk)
      Spacer()
      Text("Warm Studio")
        .font(TypeScale.editorialAccent)
        .foregroundStyle(theme.secondaryInk.opacity(0.75))
    }
    .padding(.horizontal, Layout.normal)
    .padding(.vertical, 8)
  }

  /// The map speaks in displays; the sidebar speaks in pages.
  ///
  /// Reading gives a display only while one is actually being shown, so
  /// clicking a rectangle while the Schedule page is open still selects it and
  /// nothing about the map is highlighted in the meantime.
  private var mapSelection: Binding<DisplayViewModel.ID?> {
    Binding(
      get: {
        if case let .display(id) = router.route { return id }
        return nil
      },
      set: { id in
        if let id { router.route = .display(id) }
      }
    )
  }

  // MARK: - Detail

  @ViewBuilder
  private var page: some View {
    switch router.route {
    case let .display(id):
      if let display = model.displays.first(where: { $0.id == id }) {
        DisplayPage(model: model, display: display, log: model.log,
                    groupChangeTick: model.groupChangeTick)
      } else {
        // Reached for one frame at most — `SettingsRouter.repair` moves off a
        // display that has gone — but a `switch` has to answer for it.
        noDisplays
      }
    case .remembered:
      RememberedDisplays(model: model)
        .navigationTitle("Bekannte Displays")
    case let .app(app):
      appPage(app).navigationTitle(app.title)
    }
  }

  @ViewBuilder
  private func appPage(_ app: AppPage) -> some View {
    switch app {
    case .general: GeneralSettings(model: model)
    case .updates: UpdateSettings(model: model)
    case .keys: KeySettings(model: model)
    case .presets: PresetSettings(model: model)
    case .schedule: ScheduleSettings(model: model)
    case .apps: AppRuleSettings(model: model)
    case .shortcuts: ShortcutSettings(model: model)
    }
  }

  private var noDisplays: some View {
    CharacterfulEmptyState(
      title: "Suche nach Displays…",
      message: "Externe Monitore erscheinen hier automatisch, sobald sie angeschlossen sind."
    ) {
      SearchingRadar()
    }
    .navigationTitle("Displays")
  }
}

/// A row in the sidebar: something to look at, a name, and what it holds.
///
/// The summary line is the point of the row. A sidebar of six nouns has to be
/// opened one page at a time to find anything; a sidebar that says "Media keys,
/// permissions, detection" under "Keys" does not.
private struct SidebarItemButton<Content: View>: View {
  let isSelected: Bool
  let accent: Color
  let namespace: Namespace.ID
  let action: () -> Void
  @ViewBuilder let content: (Bool) -> Content

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  var body: some View {
    Button {
      action()
      Haptics.detent()
    } label: {
      content(isHovered)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
              .fill(theme.sidebarSelectionFill)
              .overlay {
                RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
                  .strokeBorder(theme.specularRim, lineWidth: 0.75)
              }
              .overlay {
                RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
                  .strokeBorder(theme.sidebarSelectionBorder(for: accent), lineWidth: 1)
              }
              .shadow(color: accent.opacity(theme.isDark ? 0.20 : 0.10), radius: 4, y: 1)
              .matchedGeometryEffect(id: "sidebarSelection", in: namespace)
          } else if isHovered {
            RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous)
              .fill(theme.sidebarHoverFill)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: Layout.radiusControl, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(motion.effectFast, value: isHovered)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

private struct SidebarRow<Leading: View>: View {
  let title: String
  let summary: String
  var trailingText: String? = nil
  var isSelected: Bool = false
  var isHovered: Bool = false
  @ViewBuilder var leading: (Bool) -> Leading

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: Layout.tight) {
      leading(isHovered)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(title)
            .font(TypeScale.rowTitle)
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
          Spacer(minLength: 2)
          if let trailingText {
            Text(trailingText)
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(theme.secondaryInk)
              .contentTransition(.numericText())
              .animation(motion.effectFast, value: trailingText)
          }
        }
        Text(summary)
          .font(TypeScale.detail)
          .foregroundStyle(theme.secondaryInk)
          .lineLimit(1)
      }
    }
  }
}

extension SidebarRow {
  init(
    title: String,
    summary: String,
    symbolName: String,
    tint: Color? = nil,
    isSelected: Bool = false,
    isHovered: Bool = false
  ) where Leading == SidebarSymbol {
    self.init(
      title: title,
      summary: summary,
      isSelected: isSelected,
      isHovered: isHovered
    ) { hovered in
      SidebarSymbol(
        systemImage: symbolName,
        tint: tint,
        isSelected: isSelected,
        isHovered: hovered
      )
    }
  }
}

/// 20×20pt rounded-square category badge (`5pt` `Layout.radiusSegment` radius).
private struct SidebarSymbol: View {
  let systemImage: String
  var tint: Color?
  var isSelected: Bool = false
  var isHovered: Bool = false

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  private var tone: Color { tint ?? theme.tone }

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(theme.ink(for: tone))
      .symbolEffect(.bounce, value: isSelected)
      .frame(width: 20, height: 20)
      .background(
        RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
          .fill(theme.wash(for: tone))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Layout.radiusSegment, style: .continuous)
          .strokeBorder(theme.rim(for: tone).opacity(0.45), lineWidth: 0.75)
      )
      .scaleEffect(isHovered && !motion.isReduced ? 1.08 : 1.0)
      .animation(motion.spatialFast, value: isHovered)
  }
}
