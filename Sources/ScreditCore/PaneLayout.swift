/// Which panes are showing and which has the keyboard. The rules follow
/// JetBrains' Project panel: one key shows the browser, moves into it, or hides
/// it; leaving an unpinned browser hides it.
public struct PaneLayout: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case browserOnly, split, editorOnly }
    public enum Pane: Equatable, Sendable { case browser, editor }

    public private(set) var mode: Mode
    public private(set) var focus: Pane
    public private(set) var isPinned = false
    /// False until a file is open: before that there is no editor worth
    /// showing, so the full-window browser stays put.
    private var editorHasFile: Bool

    public init(startsInBrowser: Bool) {
        mode = startsInBrowser ? .browserOnly : .editorOnly
        focus = startsInBrowser ? .browser : .editor
        editorHasFile = !startsInBrowser
    }

    /// Cmd+1: show the browser and go to it; go to it if it's showing; hide it
    /// if you're in it.
    public mutating func toggleBrowser() {
        switch (mode, focus) {
        case (.editorOnly, _):
            mode = .split
            focus = .browser
        case (.split, .editor):
            focus = .browser
        case (.split, .browser), (.browserOnly, _):
            hideBrowser()
        }
    }

    /// Esc in the browser: back to the editor, hiding the browser unless pinned.
    public mutating func leaveBrowser() {
        guard focus == .browser, editorHasFile else { return }
        focus = .editor
        mode = isPinned ? .split : .editorOnly
    }

    /// Cmd+Shift+1. Pinning shows the browser; unpinning hides it unless
    /// you're in it (then it hides when you leave).
    public mutating func togglePin() {
        isPinned.toggle()
        if isPinned, mode == .editorOnly {
            mode = .split
        } else if !isPinned, mode == .split, focus == .editor {
            mode = .editorOnly
        }
    }

    /// The browser opened a file in the editor.
    public mutating func openedFile() {
        editorHasFile = true
        focus = .editor
        mode = isPinned ? .split : .editorOnly
    }

    /// The user clicked into a pane.
    public mutating func clicked(_ pane: Pane) {
        switch pane {
        case .browser:
            focus = .browser
        case .editor:
            guard editorHasFile else { return }
            focus = .editor
            if !isPinned, mode == .split { mode = .editorOnly }
        }
    }

    private mutating func hideBrowser() {
        guard editorHasFile else { return }
        mode = .editorOnly
        focus = .editor
    }
}
