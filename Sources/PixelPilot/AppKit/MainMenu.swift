import AppKit

/// The menu bar the app puts up while it has a window open.
///
/// **It exists because the Dock icon does.** An `LSUIElement` app has no menu
/// bar and needs none; the moment it becomes `.regular` so it can appear in the
/// Dock and in ⌘-Tab, macOS gives it one whether it has built it or not, and an
/// app with no `mainMenu` gets an empty strip next to the Apple menu. That
/// looks like something failed to load.
///
/// It is also the only place the standard editing shortcuts can come from.
/// ⌘C and ⌘V in a text field are not built into the field — they are key
/// equivalents on menu items, matched through the responder chain — so without
/// an Edit menu the shortcut recorder and the numeric readouts are fields you
/// cannot paste into. The items below carry no action of their own: `nil`
/// targets mean AppKit sends the selector down the responder chain, and
/// whatever is focused answers it.
///
/// Deliberately short. This is a menu bar for a menu bar app: enough to close a
/// window, edit a field and quit, and nothing that duplicates what the settings
/// window already says better.
@MainActor
enum MainMenu {
  static func make(appName: String, settingsAction: (target: AnyObject, selector: Selector))
    -> NSMenu
  {
    let menu = NSMenu()
    menu.addItem(appMenu(appName: appName, settingsAction: settingsAction))
    menu.addItem(editMenu())
    menu.addItem(windowMenu())
    return menu
  }

  private static func appMenu(
    appName: String, settingsAction: (target: AnyObject, selector: Selector)
  ) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: appName)

    menu.addItem(
      withTitle: "About \(appName)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())

    let settings = NSMenuItem(
      title: "Settings…", action: settingsAction.selector, keyEquivalent: ","
    )
    settings.target = settingsAction.target
    menu.addItem(settings)
    menu.addItem(.separator())

    menu.addItem(
      withTitle: "Hide \(appName)",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(hideOthers)
    menu.addItem(.separator())

    menu.addItem(
      withTitle: "Quit \(appName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    item.submenu = menu
    return item
  }

  private static func editMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Edit")

    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redo)
    menu.addItem(.separator())

    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
    )

    item.submenu = menu
    return item
  }

  private static func windowMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Window")

    menu.addItem(
      withTitle: "Minimise", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"
    )
    // ⌘W closes the window rather than quitting, which is what
    // `applicationShouldTerminateAfterLastWindowClosed` returning false is for:
    // this is a menu bar app and it goes on running with nothing on screen.
    menu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
    )

    item.submenu = menu
    NSApp.windowsMenu = menu
    return item
  }
}
