import Testing

@testable import PixelPilot

/// The one piece of the settings window that is decision rather than layout:
/// what happens to the page you are on when the displays underneath it change.
@Suite("Settings routing")
@MainActor
struct SettingsRouteTests {
  @Test("A display page survives as long as its display does")
  func keepsLivingDisplay() {
    let router = SettingsRouter()
    router.route = .display("a")

    router.repair(against: ["a", "b"])

    #expect(router.route == .display("a"))
  }

  /// The reason this exists: unplugging the monitor whose page is open used to
  /// be the one way to reach a detail pane with nothing in it.
  @Test("Unplugging the display being shown moves to another one")
  func movesOffDeadDisplay() {
    let router = SettingsRouter()
    router.route = .display("a")

    router.repair(against: ["b"])

    #expect(router.route == .display("b"))
  }

  /// With nothing left to show, the page that lists displays which are *not*
  /// connected is the only one still about the thing being looked at.
  @Test("With every display gone, remembered displays is where it lands")
  func fallsBackToRemembered() {
    let router = SettingsRouter()
    router.route = .display("a")

    router.repair(against: [])

    #expect(router.route == .remembered)
  }

  /// Reading the schedule while a monitor is unplugged is not a reason to be
  /// thrown onto a different page.
  @Test("An app page is never moved off, whatever happens to the displays")
  func leavesAppPagesAlone() {
    for page in AppPage.allCases {
      let router = SettingsRouter()
      router.route = .app(page)

      router.repair(against: [])
      #expect(router.route == .app(page))

      router.repair(against: ["a"])
      #expect(router.route == .app(page))
    }
  }

  @Test("Remembered displays stays put when a display appears")
  func leavesRememberedAlone() {
    let router = SettingsRouter()
    router.route = .remembered

    router.repair(against: ["a"])

    #expect(router.route == .remembered)
  }

  /// Every page in the sidebar has to say what it holds — that line is the
  /// whole reason the window has a sidebar rather than a row of tabs.
  @Test("Every app page carries a title, a summary and a symbol")
  func pagesDescribeThemselves() {
    for page in AppPage.allCases {
      #expect(!page.title.isEmpty)
      #expect(!page.summary.isEmpty)
      #expect(!page.symbolName.isEmpty)
    }
  }
}
