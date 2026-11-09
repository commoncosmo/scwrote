/// The window's own keys, caught before the terminal sees them. All use Cmd:
/// nvim never gets Cmd keys, so these take nothing away from it.
public enum WindowShortcut: Equatable, Sendable {
    /// Cmd+1: show the browser and go to it, go to it, or hide it.
    case toggleBrowser
    /// Cmd+Shift+1.
    case toggleBrowserPin
    /// Cmd+[: go to the browser, showing it if hidden.
    case goToBrowser
    /// Cmd+]: go to the editor.
    case goToEditor

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// `keyCode` is the physical key (a macOS virtual key code), so Cmd+Shift+1
    /// matches whatever character Shift+1 types.
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        switch (keyCode, modifiers) {
        case (18, [.command]): self = .toggleBrowser
        case (18, [.command, .shift]): self = .toggleBrowserPin
        case (33, [.command]): self = .goToBrowser
        case (30, [.command]): self = .goToEditor
        default: return nil
        }
    }
}
