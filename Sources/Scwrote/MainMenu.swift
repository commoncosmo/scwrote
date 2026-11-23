import AppKit

/// App and Window menus, so Cmd+Q, Cmd+H and Cmd+W work. No Edit menu: copy
/// and paste are Ghostty key bindings (Cmd+C / Cmd+V) handled by the terminal.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let appMenu = NSMenu(title: "scwrote")
        appMenu.addItem(withTitle: "About scwrote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // The editor window catches Cmd+, itself (see EditorWindow); this
        // item's key equivalent is what takes it in the Settings window.
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide scwrote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit scwrote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // The window catches these keys first (see EditorWindow); the items
        // make them discoverable and clickable.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle File Browser", action: #selector(EditorWindowController.toggleFileBrowser(_:)), keyEquivalent: "1")
        let pin = viewMenu.addItem(withTitle: "Pin File Browser", action: #selector(EditorWindowController.toggleFileBrowserPin(_:)), keyEquivalent: "1")
        pin.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Toggle Preview", action: #selector(EditorWindowController.togglePreview(_:)), keyEquivalent: "2")
        // Enabled while the shown HTML has remote content blocked; `R` in the
        // preview does the same.
        viewMenu.addItem(withTitle: "Load Remote Content", action: #selector(EditorWindowController.loadRemoteContent(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Move to Left Pane", action: #selector(EditorWindowController.moveToLeftPane(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Move to Right Pane", action: #selector(EditorWindowController.moveToRightPane(_:)), keyEquivalent: "]")
        viewMenu.addItem(.separator())
        let find = viewMenu.addItem(withTitle: "Find in Folder", action: #selector(EditorWindowController.toggleSearch(_:)), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command, .shift]
        let quickOpen = viewMenu.addItem(withTitle: "Quick Open", action: #selector(EditorWindowController.toggleQuickOpen(_:)), keyEquivalent: "o")
        quickOpen.keyEquivalentModifierMask = [.command, .shift]

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for menu in [appMenu, viewMenu, windowMenu] {
            mainMenu.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }
}
