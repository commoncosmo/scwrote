import AppKit
import GhosttyTerminal
import ScwroteCore

/// One window: the file browser, a Ghostty terminal surface running nvim and
/// the preview, shown according to `PaneLayout`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// True until nvim exits. Closing the window while it runs hangs up on it.
    private(set) var isNvimRunning = true
    /// Set as the window closes, when its connections to nvim are let go.
    private(set) var isClosing = false

    let terminalView = EditorTerminalView(frame: .zero)
    let browserView: FileBrowserView
    let previewView: PreviewPaneView
    let layoutView: EditorLayoutView
    private(set) var panes: PaneLayout

    /// What the preview shows (see EditorWindowController+Preview).
    var previewState = PreviewState()
    /// nvim's newest cursor and the file it is in. A buffer snapshot's own
    /// cursor goes stale as `.cursor` events arrive.
    var latestCursor: (path: String, position: CursorPosition)?
    /// The shown buffer's line count, for following HTML by proportion.
    var previewLineCount = 1
    /// Something changed while the preview was hidden (or it never rendered):
    /// render when it is shown.
    var isPreviewOutOfDate = true

    /// nvim's RPC socket. Calls block, so they run on `nvimQueue`.
    private let nvim: NvimClient
    private let nvimQueue = DispatchQueue(label: "scwrote.nvim")
    /// A second connection that only listens, for the preview.
    let previewEvents: NvimEventListener
    private var watcher: FolderWatcher?
    /// Add, rename and delete for the browser's folder; follows its root.
    private var fileActions: FileActions

    /// `controller` carries the nvim command in its config (see
    /// `GhosttyConfig.editorConfig` for why it isn't a surface option).
    init(request: LaunchRequest, controller: TerminalController, nvimSocket: String, theme: Theme) {
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = request.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Ghostty's default look: the title bar takes the terminal's background.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = theme.background
        window.contentMinSize = NSSize(width: 360, height: 200)

        browserView = FileBrowserView(browser: FileBrowser(root: request.browserRoot), theme: theme)
        previewView = PreviewPaneView(theme: theme)
        panes = PaneLayout(startsInBrowser: request.startsInBrowser)
        layoutView = EditorLayoutView(
            browserView: browserView,
            editorView: TerminalContainerView(terminalView: terminalView),
            previewView: previewView,
            panes: panes,
            dividerColor: theme.divider
        )
        nvim = NvimClient(socketPath: nvimSocket)
        previewEvents = NvimEventListener(socketPath: nvimSocket)
        fileActions = FileActions(root: request.browserRoot, fileSystem: LocalFileSystem())
        super.init(window: window)

        window.delegate = self
        window.onShortcut = { [weak self] in self?.perform($0) }

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: request.workingDirectory
        )
        terminalView.controller = controller
        terminalView.onClick = { [weak self] in self?.change { $0.clicked(.editor) } }

        browserView.onClick = { [weak self] in self?.change { $0.clicked(.browser) } }
        browserView.onAction = { [weak self] in self?.handle($0) }
        browserView.onRootChange = { [weak self] in self?.browserRootChanged($0) }
        browserView.onPrompt = { [weak self] in self?.finishPrompt($0) }

        layoutView.onGaveWay = { [weak self] in self?.panesGaveWay($0) }
        connectPreview()

        window.contentView = layoutView
        window.center()
        watch(request.browserRoot)
        applyPanes()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyPanes()
        runDebugHooks()
    }

    // MARK: - Panes

    /// Cmd+1 (View menu): show the browser and go to it, go to it, or hide it.
    @objc func toggleFileBrowser(_: Any?) {
        browserView.prompt = nil
        change { $0.toggleBrowser() }
    }

    /// Cmd+Shift+1 (View menu).
    @objc func toggleFileBrowserPin(_: Any?) {
        browserView.prompt = nil
        change { $0.togglePin() }
    }

    /// Cmd+2 (View menu): show the preview and go to it, go to it, or hide it
    /// (also when the window has no room to show it).
    @objc func togglePreview(_: Any?) {
        browserView.prompt = nil
        let squeezedOut = layoutView.gaveWay(for: panes).contains(.preview)
        change { $0.togglePreview(squeezedOut: squeezedOut) }
    }

    /// Cmd+[ (View menu): one pane to the left.
    @objc func moveToLeftPane(_: Any?) {
        browserView.prompt = nil
        change { $0.moveLeft() }
    }

    /// Cmd+] (View menu): one pane to the right.
    @objc func moveToRightPane(_: Any?) {
        browserView.prompt = nil
        change { $0.moveRight() }
    }

    /// View menu: let the shown HTML file's remote content load (also `R` in
    /// the preview, or a click on the header's note).
    @objc func loadRemoteContent(_: Any?) {
        previewView.loadRemoteContent()
    }

    private func perform(_ shortcut: WindowShortcut) {
        switch shortcut {
        case .toggleBrowser: toggleFileBrowser(nil)
        case .toggleBrowserPin: toggleFileBrowserPin(nil)
        case .togglePreview: togglePreview(nil)
        case .moveLeft: moveToLeftPane(nil)
        case .moveRight: moveToRightPane(nil)
        }
    }

    /// Applies a layout change. The keyboard never goes to a pane the window
    /// has no room for. A browser that just appeared opens on the file being
    /// edited; a preview that just appeared catches up with nvim; coming back
    /// to the editor points the preview back at nvim's buffer and cursor
    /// (being sent there because a pane gave way doesn't count).
    func change(_ update: (inout PaneLayout) -> Void) {
        let old = panes
        update(&panes)
        let returnsToEditor = old.focus != .editor && panes.focus == .editor
        if layoutView.gaveWay(for: panes).contains(panes.focus) { panes.paneGaveWay(panes.focus) }
        applyPanes()
        if old.mode == .editorOnly, panes.mode != .editorOnly { revealCurrentFile() }
        if !old.isPreviewShown, panes.isPreviewShown { previewAppeared() }
        if old.isPreviewShown, !panes.isPreviewShown { previewDisappeared() }
        if returnsToEditor { previewReturnedToEditor() }
    }

    private func applyPanes() {
        layoutView.panes = panes
        browserView.isPinned = panes.isPinned
        let focused: NSView = switch panes.focus {
        case .browser: browserView
        case .editor: terminalView
        case .preview: previewView
        }
        if window?.firstResponder !== focused { window?.makeFirstResponder(focused) }
    }

    /// Panes squeezed out for lack of room give up the keyboard. That isn't
    /// the user returning to the editor, so the preview stays as it is.
    private func panesGaveWay(_ gone: Set<PaneLayout.Pane>) {
        let old = panes
        for pane in gone { panes.paneGaveWay(pane) }
        if panes != old { applyPanes() }
    }

    private func handle(_ action: BrowserAction) {
        switch action {
        case .leave: change { $0.leaveBrowser() }
        case let .open(path): choose(path)
        case .add:
            let browser = browserView.browser
            let folder = fileActions.folderForNewItem(selected: browser.selectedEntry)
            browserView.prompt = .add(folder: folder, root: browser.root)
        case let .rename(path):
            browserView.prompt = .rename(path: path)
        case let .delete(path):
            let question = fileActions.deleteQuestion(for: path, hasUnsavedChanges: hasUnsavedChanges(at: path))
            browserView.prompt = .delete(path: path, question: question)
        }
    }

    /// Whether the item at a browser path, or anything inside it, has
    /// unsaved changes in nvim.
    private func hasUnsavedChanges(at path: String) -> Bool {
        let browser = browserView.browser
        let isDirectory = browser.rows.first { $0.entry.path == path }?.entry.isDirectory ?? false
        return browserView.unsaved.marks(FileBrowser.nvimPath(of: path), isDirectory: isDirectory)
    }

    // MARK: - File actions

    /// Carries out what the prompt asked for. A refused or failed action
    /// leaves the prompt open with the reason; otherwise it closes, and the
    /// browser shows the result at once rather than waiting for the folder
    /// watcher.
    private func finishPrompt(_ outcome: BrowserPrompt.Outcome) {
        guard let prompt = browserView.prompt else { return }
        switch (prompt.kind, outcome) {
        case let (.add(folder), .submitted(name)):
            switch fileActions.create(name, in: folder) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case let .success(item): added(item)
            }
        case let (.rename(path), .submitted(name)):
            // Resolved now: once the item has moved there's nothing to resolve.
            let oldNvimPath = FileBrowser.nvimPath(of: path)
            switch fileActions.rename(path, to: name) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case .success(nil): browserView.prompt = nil
            case let .success(newPath?): renamed(from: oldNvimPath, to: newPath)
            }
        case let (.delete(path, _), .confirmed):
            let nvimPath = FileBrowser.nvimPath(of: path)
            switch fileActions.delete(path) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case .success: deleted(nvimPath: nvimPath)
            }
        default:
            browserView.prompt = nil
        }
    }

    /// A new file opens as if chosen; a new folder is selected.
    private func added(_ item: NewItem) {
        browserView.prompt = nil
        browserView.reload()
        browserView.reveal(item.path)
        if !item.isFolder { choose(item.path) }
    }

    /// nvim's buffers take the new name, keeping unsaved changes.
    private func renamed(from oldNvimPath: String, to newPath: String) {
        browserView.prompt = nil
        browserView.reload()
        browserView.reveal(newPath)
        let newNvimPath = FileBrowser.nvimPath(of: newPath)
        syncNvim("follow the rename of \(oldNvimPath)") { try $0.renameBuffers(from: oldNvimPath, to: newNvimPath) }
    }

    /// The cursor stays where the item was (on the row that took its place).
    private func deleted(nvimPath: String) {
        browserView.prompt = nil
        browserView.reload()
        syncNvim("close the buffers of \(nvimPath)") { try $0.closeBuffers(at: nvimPath) }
    }

    /// The disk change stands even if nvim can't follow it, so a failure is
    /// only reported: a beep, and the first line on stderr (nvim's own
    /// message, without the Lua traceback after it).
    private func syncNvim(_ what: String, _ work: @escaping @Sendable (NvimClient) throws -> Void) {
        Task {
            do {
                try await nvimCall(work)
            } catch {
                NSSound.beep()
                let message: String = if case let NvimClient.Failure.nvim(text) = error { text } else { "\(error)" }
                let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
                FileHandle.standardError.write(Data("scwrote: nvim couldn't \(what): \(firstLine)\n".utf8))
            }
        }
    }

    // MARK: - nvim

    /// Opens a file chosen in the browser or a preview link: images and PDFs
    /// in the preview, anything else in nvim.
    func choose(_ path: String) {
        if PreviewKind(path: path).isViewOnly {
            showViewOnly(path)
        } else {
            open(path)
        }
    }

    private func open(_ path: String) {
        Task {
            do {
                try await nvimCall { try $0.edit(path) }
                window?.title = (path as NSString).lastPathComponent
                change { $0.openedFile() }
            } catch {
                NSSound.beep()
                FileHandle.standardError.write(Data("scwrote: couldn't open \(path) in nvim: \(error)\n".utf8))
            }
        }
    }

    private func revealCurrentFile() {
        Task {
            guard let file = try? await nvimCall({ try $0.currentFile() }) else { return }
            browserView.reveal(file)
        }
    }

    func nvimCall<T: Sendable>(_ work: @escaping @Sendable (NvimClient) throws -> T) async throws -> T {
        let nvim = nvim
        return try await withCheckedThrowingContinuation { continuation in
            nvimQueue.async { continuation.resume(with: Result { try work(nvim) }) }
        }
    }

    // MARK: - Files on disk

    /// `-` moved the browser: actions follow the new root, and a prompt
    /// opened for the old one closes.
    private func browserRootChanged(_ root: String) {
        browserView.prompt = nil
        fileActions = FileActions(root: root, fileSystem: LocalFileSystem())
        watch(root)
    }

    private func watch(_ root: String) {
        watcher?.stop()
        watcher = FolderWatcher(path: root) { [weak self] in
            guard let self else { return }
            browserView.reload()
            if case .viewOnly = previewState.target {
                if panes.isPreviewShown { previewView.reloadFromDisk() } else { isPreviewOutOfDate = true }
            }
        }
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isNvimRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "nvim is still running. Any unsaved changes will be lost."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.isNvimRunning = false
            sender.close()
        }
        return false
    }

    func windowWillClose(_: Notification) {
        isClosing = true
        watcher?.stop()
        previewEvents.stop()
        onClose?()
    }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFileBrowserPin(_:)) {
            item.title = panes.isPinned ? "Unpin File Browser" : "Pin File Browser"
        }
        if item.action == #selector(loadRemoteContent(_:)) {
            return panes.isPreviewShown && previewView.hasBlockedRemoteContent
        }
        return true
    }
}

extension EditorWindowController: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate,
    TerminalSurfaceGridResizeDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        window?.title = title
    }

    /// Ghostty measured its cells (at start, or after a resize or font zoom):
    /// the browser's rows follow its line height.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        let scale = terminalView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let height = RowGrid.cellHeight(pixels: size.cellHeightPixels, scale: Double(scale)) else { return }
        browserView.cellHeight = CGFloat(height)
    }

    /// Ghostty asks the host to close the surface: after nvim exits, or on a
    /// close key binding while it still runs (which goes through the prompt).
    func terminalDidClose(processAlive: Bool) {
        if processAlive {
            window?.performClose(nil)
        } else {
            isNvimRunning = false
            window?.close()
        }
    }
}

/// Catches the window's own keys (`WindowShortcut`: Cmd+1, Cmd+Shift+1,
/// Cmd+2, Cmd+[, Cmd+]) before the terminal sees them: Ghostty binds Cmd+digit to
/// tabs and Cmd+[ / Cmd+] to splits, neither of which scwrote has.
@MainActor
final class EditorWindow: NSWindow {
    var onShortcut: ((WindowShortcut) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let shortcut = WindowShortcut(keyCode: event.keyCode, modifiers: Self.modifiers(of: event)) {
            onShortcut?(shortcut)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func modifiers(of event: NSEvent) -> WindowShortcut.Modifiers {
        let flags = event.modifierFlags
        var modifiers: WindowShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

/// The terminal, reporting clicks so a click into the editor counts as
/// leaving the browser.
@MainActor
final class EditorTerminalView: TerminalView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// Keeps the terminal filling its pane and its grid sized to match.
private final class TerminalContainerView: NSView {
    private let terminalView: TerminalView

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        terminalView.fitToSize()
    }
}
