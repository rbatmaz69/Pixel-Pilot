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
  case overview, general, updates, keys, presets, schedule, apps, shortcuts

  /// The pages that belong in the sidebar's "App" section.
  ///
  /// Everything except `overview`, which is drawn on its own above both
  /// sections because it is about both of them. Written as a list rather than
  /// as a filter at the call site so that a page added later cannot quietly go
  /// missing from the sidebar — `SettingsRouteTests` checks this against
  /// `allCases`, which a `filter` would have made unfalsifiable.
  static let appSection: [AppPage] = [
    .general, .updates, .keys, .presets, .schedule, .apps, .shortcuts,
  ]

  var title: String {
    switch self {
    case .overview: "Overview"
    case .general: "General"
    case .updates: "Updates"
    case .keys: "Keys"
    case .presets: "Presets"
    case .schedule: "Schedule"
    case .apps: "Apps"
    case .shortcuts: "Shortcuts"
    }
  }

  var summary: String {
    switch self {
    case .overview: "Everything, in one place"
    case .general: "Colour, style, open at login"
    case .updates: "New versions, and what they cost"
    case .keys: "Media keys, permissions, detection"
    case .presets: "Saved brightness and volume sets"
    case .schedule: "Changes through the day"
    case .apps: "A preset per application"
    case .shortcuts: "Global keyboard shortcuts"
    }
  }

  var symbolName: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .general: "paintpalette"
    case .updates: "arrow.trianglehead.2.clockwise.rotate.90"
    case .keys: "keyboard"
    case .presets: "square.stack"
    case .schedule: "sun.horizon"
    case .apps: "app.badge"
    case .shortcuts: "command"
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
  /// Opens on the overview, which is the one page that answers "is everything
  /// alright" without being asked a narrower question first.
  var route: SettingsRoute = .app(.overview)

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

  /// What is being searched for, if anything. `@State` rather than on the
  /// router: unlike the selected page, a half-typed query is not somewhere to
  /// come back to, and a window reopening into somebody's abandoned search
  /// would be a sidebar that had gone missing.
  @State private var query = ""
  @FocusState private var isSearchFocused: Bool

  private var results: [SearchEntry<SettingsRoute>] {
    // Built only while there is something to match against, which is the whole
    // of what keeps this off the idle budget: with an empty field nothing is
    // allocated and nothing is ranked.
    guard !query.isEmpty else { return [] }
    return SettingsSearch.rank(query, in: SettingsSearchIndex.entries(model: model))
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      page
    }
    .onAppear { router.repair(against: model.displays.map(\.id)) }
    .onChange(of: model.displays.map(\.id)) { _, ids in
      router.repair(against: ids)
    }
    // Choosing a result puts the sidebar back rather than leaving a filtered
    // one behind the page it just took you to.
    .onChange(of: router.route) { _, _ in
      query = ""
      isSearchFocused = false
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    // Still a `List` with a system selection rather than a custom stack with
    // a sliding pill. The pill would look better and would cost arrow-key
    // navigation of the sidebar, which is not a trade worth making for a
    // highlight.
    VStack(spacing: 0) {
      // At the top, where the eye starts, and above the things it filters.
      SettingsSearchField(query: $query, isFocused: $isSearchFocused)
        .padding(.horizontal, Layout.snug)
        .padding(.top, Layout.snug)

      // ⌘F, as a button with no size. `.hidden()` is not usable here: a hidden
      // view does not take part in key equivalents, so the shortcut would
      // simply never fire.
      Button("Search") { isSearchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)

      if model.displays.count > 1, query.isEmpty {
        // Only with more than one. A map of a single display is a rectangle
        // saying what the row below it already says.
        DisplayMap(
          displays: model.displays,
          selection: mapSelection,
          layoutTick: model.screenLayoutTick
        )
        .padding(.horizontal, Layout.snug)
        .padding(.top, Layout.snug)

        Button {
          model.identifyDisplays()
        } label: {
          Label("Identify", systemImage: "number.circle")
            .font(TypeScale.detail.weight(.medium))
        }
        .buttonStyle(.soft)
        .padding(.vertical, Layout.tight)
      }

      List(selection: listSelection) {
        if query.isEmpty {
          sections
        } else {
          resultRows
        }
      }
      // A `List` paints the system's sidebar material over whatever is behind
      // it, which here is the theme's field. Hiding it is what keeps the
      // sidebar the same colour as the rest of the window.
      .scrollContentBackground(.hidden)
      .animation(motion.spatialDefault, value: model.displays.map(\.id))
      // Escape gets out of a search without going anywhere. Landing somewhere
      // you did not choose is what a cancelled search must not do.
      .onExitCommand {
        query = ""
        isSearchFocused = false
      }
    }
    .navigationSplitViewColumnWidth(min: 240, ideal: 260)
  }

  /// The sidebar as it normally is.
  @ViewBuilder
  private var sections: some View {
    Group {
      // Before the first `Section`, which a macOS sidebar list renders as its
      // own ungrouped block at the top — exactly the right reading. This row
      // is in neither group because it is about both.
      SidebarRow(
        title: AppPage.overview.title,
        summary: AppPage.overview.summary,
        symbolName: AppPage.overview.symbolName
      )
      .tag(SettingsRoute.app(.overview))

      Section("Displays") {
        ForEach(model.displays) { display in
          SidebarRow(
            title: display.name,
            summary: display.isBuiltin ? "Built-in" : display.routeDescription
          ) {
            // The dot rather than a symbol: this row is the one place the
            // display's own colour has to be recognisable, because it is what
            // ties the sidebar to the map above it and to the cards on the
            // right.
            AccentDot(accent: display.accent, isReady: display.isReady, size: 9)
              .frame(width: 22)
          }
          .tag(SettingsRoute.display(display.id))
        }

        SidebarRow(
          title: "Remembered",
          summary: "Displays seen before, connected or not",
          symbolName: "externaldrive.badge.checkmark"
        )
        .tag(SettingsRoute.remembered)
      }

      Section("App") {
        ForEach(AppPage.appSection, id: \.self) { app in
          SidebarRow(
            title: app.title,
            summary: app.summary,
            symbolName: app.symbolName
          )
          .tag(SettingsRoute.app(app))
        }
      }
    }
  }

  /// What was typed, answered.
  ///
  /// Results **instead of** the sections rather than above them. A sidebar
  /// showing eight matches and then the fifteen ordinary rows underneath is a
  /// scroll, and the whole point of typing was to stop scrolling.
  ///
  /// The same `SidebarRow`, the same `List` and the same selection binding as
  /// the sections, which is what makes ↑/↓ and Return work here with no extra
  /// code at all — the same argument the comment above makes for keeping a
  /// `List` in the first place.
  @ViewBuilder
  private var resultRows: some View {
    if results.isEmpty {
      Text("Nothing matches “\(query)”.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .padding(.vertical, Layout.tight)
    } else {
      Section("Results") {
        ForEach(results) { entry in
          SidebarRow(
            title: entry.title,
            summary: entry.context,
            symbolName: "arrow.turn.down.right"
          )
          .tag(entry.target)
        }
      }
    }
  }

  /// The list's selection, which is optional where the router's is not.
  ///
  /// A `List` hands back `nil` for "nothing is selected" — clicking the empty
  /// space under the last row does it. There is no such page, so that is
  /// dropped and the window stays where it is, rather than emptying the whole
  /// right-hand side because of a stray click.
  private var listSelection: Binding<SettingsRoute?> {
    Binding(
      get: { router.route },
      set: { route in if let route { router.route = route } }
    )
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
        .navigationTitle("Remembered displays")
    case let .app(app):
      appPage(app).navigationTitle(app.title)
    }
  }

  @ViewBuilder
  private func appPage(_ app: AppPage) -> some View {
    switch app {
    case .overview: OverviewPage(model: model, router: router)
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
      title: "Looking for displays",
      message: "Nothing is answering on the DDC bus yet. External monitors appear here "
        + "as soon as they are connected."
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
private struct SidebarRow<Leading: View>: View {
  let title: String
  let summary: String
  @ViewBuilder var leading: Leading

  var body: some View {
    HStack(spacing: Layout.tight) {
      leading
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(TypeScale.rowTitle)
        Text(summary)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 3)
  }
}

extension SidebarRow {
  /// The symbol form, drawn the way a card's heading draws its symbol — so a
  /// page and the row that leads to it are recognisably the same thing.
  init(title: String, summary: String, symbolName: String) where Leading == SidebarSymbol {
    self.init(title: title, summary: summary) {
      SidebarSymbol(systemImage: symbolName)
    }
  }
}

/// The same glyph a card puts beside its heading, at the same size — so a page
/// and the row that leads to it are recognisably the same thing.
private struct SidebarSymbol: View {
  let systemImage: String

  @Environment(\.theme) private var theme

  private var tone: Color { theme.tone }

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(theme.ink(for: tone))
      .frame(width: 22, height: 22)
      .background(Circle().fill(theme.wash(for: tone)))
  }
}
