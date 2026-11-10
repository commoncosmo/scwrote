/// Which panes are showing and which has the keyboard. The rules follow
/// JetBrains' Project panel: one key shows the browser, moves into it, or hides
/// it; leaving an unpinned browser hides it.
public struct PaneLayout: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case browserOnly, split, editorOnly }
    public enum Pane: Hashable, Sendable { case browser, editor, preview }

    public private(set) var mode: Mode
    public private(set) var focus: Pane
    public private(set) var isPinned = false
    /// Whether the preview pane shows, to the right of the editor.
    public private(set) var isPreviewShown = false
    /// False until a file is open: before that there is no editor worth
    /// showing, so the full-window browser stays put.
    public private(set) var editorHasFile: Bool

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
        case (.split, .editor), (.split, .preview):
            focus = .browser
        case (.split, .browser), (.browserOnly, _):
            hideBrowser()
        }
    }

    /// Cmd+[: show the browser if hidden and go to it. Never hides it, unlike
    /// Cmd+1, so pressing it twice leaves you in the browser.
    public mutating func focusBrowser() {
        if mode == .editorOnly { mode = .split }
        focus = .browser
    }

    /// Cmd+2: show the preview and go to it; go to it if it's showing; hide it
    /// if you're in it.
    public mutating func togglePreview() {
        if !isPreviewShown {
            isPreviewShown = true
            focus = .preview
        } else if focus != .preview {
            focus = .preview
        } else {
            isPreviewShown = false
            focus = editorHasFile ? .editor : .browser
        }
    }

    /// Cmd+[: one pane to the left. From the editor that's the browser, shown
    /// if hidden.
    public mutating func moveLeft() {
        switch focus {
        case .preview: focus = editorHasFile ? .editor : .browser
        case .editor: focusBrowser()
        case .browser: break
        }
    }

    /// Cmd+]: one pane to the right. From the browser that's the editor,
    /// hiding the browser unless pinned; from the editor, the preview if shown.
    public mutating func moveRight() {
        switch focus {
        case .browser: leaveBrowser()
        case .editor: if isPreviewShown { focus = .preview }
        case .preview: break
        }
    }

    /// Esc in the preview: back to the editor (or the browser before any file
    /// is open). The preview stays shown.
    public mutating func leavePreview() {
        guard focus == .preview else { return }
        focus = editorHasFile ? .editor : .browser
    }

    /// The browser chose a file only the preview can show (an image or PDF).
    /// The browser keeps the keyboard so the next file is one key away.
    public mutating func openedViewOnlyFile() {
        isPreviewShown = true
    }

    /// The window had no room for `pane`, so it was squeezed out. If it had the
    /// keyboard, the editor takes it.
    public mutating func paneGaveWay(_ pane: Pane) {
        guard focus == pane, editorHasFile else { return }
        focus = .editor
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
        case .preview:
            focus = .preview
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
