import AppKit

/// App and Window menus, so Cmd+Q, Cmd+H and Cmd+W work. No Edit menu: copy
/// and paste are Ghostty key bindings (Cmd+C / Cmd+V) handled by the terminal.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let appMenu = NSMenu(title: "scredit")
        appMenu.addItem(withTitle: "About scredit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide scredit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit scredit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // The window catches these keys first (see EditorWindow); the items
        // make them discoverable and clickable.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle File Browser", action: #selector(EditorWindowController.toggleFileBrowser(_:)), keyEquivalent: "1")
        let pin = viewMenu.addItem(withTitle: "Pin File Browser", action: #selector(EditorWindowController.toggleFileBrowserPin(_:)), keyEquivalent: "1")
        pin.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Go to File Browser", action: #selector(EditorWindowController.goToFileBrowser(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Go to Editor", action: #selector(EditorWindowController.goToEditor(_:)), keyEquivalent: "]")

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
