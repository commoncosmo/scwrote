/// The window's own keys, caught before the terminal sees them. All use Cmd:
/// nvim never gets Cmd keys, so these take nothing away from it.
public enum WindowShortcut: Equatable, Sendable {
    /// Cmd+1: show the browser and go to it, go to it, or hide it.
    case toggleBrowser
    /// Cmd+Shift+1.
    case toggleBrowserPin
    /// Cmd+2: show the preview and go to it, go to it, or hide it.
    case togglePreview
    /// Cmd+[: move one pane to the left.
    case moveLeft
    /// Cmd+]: move one pane to the right.
    case moveRight
    /// Cmd+Shift+F: open or close the search overlay.
    case search
    /// Cmd+Shift+O: open or close quick open.
    case quickOpen

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Digits and brackets match `keyCode`, the physical key (a macOS virtual
    /// key code), so Cmd+Shift+1 matches whatever character Shift+1 types.
    /// Letters match `characters`, the typed character
    /// (`charactersIgnoringModifiers`), so Cmd+Shift+F is the key that types
    /// F in the user's layout: on Dvorak the physical F key types U, and
    /// matching it there would take Cmd+Shift+U instead.
    public init?(keyCode: UInt16, characters: String?, modifiers: Modifiers) {
        switch (keyCode, modifiers) {
        case (18, [.command]): self = .toggleBrowser
        case (18, [.command, .shift]): self = .toggleBrowserPin
        case (19, [.command]): self = .togglePreview
        case (33, [.command]): self = .moveLeft
        case (30, [.command]): self = .moveRight
        default:
            switch (characters?.lowercased(), modifiers) {
            case ("f", [.command, .shift]): self = .search
            case ("o", [.command, .shift]): self = .quickOpen
            default: return nil
            }
        }
    }
}

/// Keys that belong to the overlays rather than the window.
public enum OverlayShortcut {
    /// Cmd+Shift+. (quick open: show or hide hidden files). Matches the
    /// physical period key, as Finder's does, on any layout.
    public static func isHiddenFilesToggle(keyCode: UInt16, modifiers: WindowShortcut.Modifiers) -> Bool {
        keyCode == 47 && modifiers == [.command, .shift]
    }
}
