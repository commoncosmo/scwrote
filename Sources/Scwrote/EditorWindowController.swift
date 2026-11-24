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
    /// The terminal's pane, which can cover it while a session loads.
    let editorContainer: TerminalContainerView
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
    /// Where `nvim` connects, for a one-off connection that mustn't wait
    /// behind `nvimQueue` (see EditorWindowController+Session).
    let nvimSocket: String
    /// The process's settings, shared with the Settings window.
    let settingsStore: SettingsStore
    /// What the theme takes from the Ghostty config, to build it again from
    /// nvim's colors.
    let themeBase: ThemeBase
    /// What every pane is drawn in now (see `apply(theme:)`).
    private(set) var theme: Theme
    /// Where nvim's last color report is remembered for the next launch, and
    /// the report the file holds as far as this window knows (loaded at
    /// launch, or saved since), so an equal report doesn't rewrite it.
    private let lastColorsFile: LastColorsFile
    private var savedColors: NvimColors?
    private let nvimQueue = DispatchQueue(label: "scwrote.nvim")
    /// A second connection that only listens, for the preview.
    let previewEvents: NvimEventListener
    private var watcher: FolderWatcher?
    /// Add, rename and delete for the browser's folder; follows its root.
    var fileActions: FileActions
    /// Set while a `d` waits to hear from nvim about unsaved changes.
    var pendingDelete: UUID?
    /// The browser's folder's files, listed once for search and quick open.
    /// Held here: its pending deliveries go if it's let go.
    var folderFiles: FolderFileList?
    /// Cmd+Shift+F (see EditorWindowController+Search): the overlay, kept
    /// while closed so it reopens on its last query; the search for the
    /// browser's folder; nvim's unsaved buffers, fetched as the overlay opens;
    /// and a count naming the latest query, so an older one's results never land.
    var searchView: SearchOverlayView?
    var projectSearch: ProjectSearch?
    var searchBuffers: OverlayFetch<[UnsavedBuffer]>?
    var searchGeneration = 0
    /// Cmd+Shift+O (see EditorWindowController+QuickOpen): the overlay, kept
    /// while closed so it reopens on its last query; `folderFiles`' latest
    /// list as sorted relative paths; nvim's recent files and unsaved
    /// buffers, fetched as it opens; the last ranking, for narrowing; a
    /// count naming the latest ranking, so an older one never lands; and
    /// whether the next ranking shown is an opening's first.
    var quickOpenView: QuickOpenView?
    var quickOpenFiles: [String]?
    var quickOpenFetch: OverlayFetch<QuickOpenNvimState>?
    var quickOpenRanked: QuickOpenRanked?
    var quickOpenGeneration = 0
    var quickOpenSelectsTop = false

    /// Reopening the folder where it was left (see
    /// EditorWindowController+Session): its saved session; the lock that
    /// makes this window the one keeping nvim's side, held for the window's
    /// life if it got it; whether this window loads and saves nvim's side;
    /// whether nvim's side is in place (restored, or nothing to restore), so
    /// a save before hanging up can't save a half-started nvim over it; a
    /// save before closing in progress; the window side saved already.
    let sessionFolder: SessionFolder
    let sessionLock: SessionLock
    var restoresNvim = false
    var savesNvim = false
    var isNvimSessionReady = false
    var isSavingBeforeClose = false
    var didSaveWindowSide = false
    /// The window's frame before it went full screen, saved in place of the
    /// full-screen one.
    var frameBeforeFullScreen: NSRect?

    /// `controller` carries the nvim command in its config (see
    /// `GhosttyConfig.editorConfig` for why it isn't a surface option).
    /// A launch that restores brings back `session`'s window side: frame,
    /// panes, dividers and browser (see EditorWindowController+Session).
    /// The window and every pane start in the launch theme: the report
    /// `lastColorsFile` remembers, resolved against `themeBase` (Ghostty's
    /// colors alone if there's none).
    init(
        request: LaunchRequest, session: SessionFolder, controller: TerminalController, nvimSocket: String,
        themeBase: ThemeBase, lastColorsFile: LastColorsFile, settingsStore: SettingsStore
    ) {
        let saved = request.restoresSession ? session.readWindowState() : nil
        let savedColors = lastColorsFile.load(for: .dark)
        let theme = themeBase.theme(nvim: savedColors)
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
        window.appearance = theme.appearance
        window.contentMinSize = NSSize(width: 360, height: 200)

        let browser = Self.browser(restoring: saved, launchRoot: request.browserRoot)
        browserView = FileBrowserView(browser: browser, theme: theme)
        previewView = PreviewPaneView(theme: theme)
        panes = Self.panes(restoring: saved, request: request)
        editorContainer = TerminalContainerView(terminalView: terminalView, background: theme.background)
        layoutView = EditorLayoutView(
            browserView: browserView,
            editorView: editorContainer,
            previewView: previewView,
            panes: panes,
            dividerColor: theme.divider
        )
        nvim = NvimClient(socketPath: nvimSocket)
        self.nvimSocket = nvimSocket
        previewEvents = NvimEventListener(socketPath: nvimSocket)
        fileActions = FileActions(root: browser.root, fileSystem: LocalFileSystem())
        sessionFolder = session
        sessionLock = SessionLock(path: session.lock)
        self.settingsStore = settingsStore
        self.themeBase = themeBase
        self.theme = theme
        self.lastColorsFile = lastColorsFile
        self.savedColors = savedColors
        super.init(window: window)

        window.delegate = self
        window.onShortcut = { [weak self] in self?.perform($0) }

        terminalView.delegate = self
        // A change in the terminal's appearance reaches nvim, which then sets
        // 'background' again from Ghostty's own background color. If the
        // terminal followed the window, which follows nvim's colors,
        // `:set background=light` would be put back to dark at once. So it
        // keeps the appearance of Ghostty's colors, as it had before nvim's.
        terminalView.appearance = themeBase.theme(nvim: nil).appearance
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
        browserView.onWaitCancelled = { [weak self] in self?.pendingDelete = nil }

        layoutView.onGaveWay = { [weak self] in self?.panesGaveWay($0) }
        connectPreview()
        followQuickOpenSettings()

        window.contentView = layoutView
        if let saved { restoreWindowSide(from: saved) } else { window.center() }
        watch(browser.root)
        applyPanes()
        if panes.isPreviewShown { previewAppeared() }
        startNvimRestore(request: request)
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
        closePrompt()
        closeOverlay()
        change { $0.toggleBrowser() }
    }

    /// Cmd+Shift+1 (View menu).
    @objc func toggleFileBrowserPin(_: Any?) {
        closePrompt()
        closeOverlay()
        change { $0.togglePin() }
    }

    /// Cmd+2 (View menu): show the preview and go to it, go to it, or hide it
    /// (also when the window has no room to show it).
    @objc func togglePreview(_: Any?) {
        closePrompt()
        closeOverlay()
        let squeezedOut = layoutView.gaveWay(for: panes).contains(.preview)
        change { $0.togglePreview(squeezedOut: squeezedOut) }
    }

    /// Cmd+[ (View menu): one pane to the left.
    @objc func moveToLeftPane(_: Any?) {
        closePrompt()
        closeOverlay()
        change { $0.moveLeft() }
    }

    /// Cmd+] (View menu): one pane to the right.
    @objc func moveToRightPane(_: Any?) {
        closePrompt()
        closeOverlay()
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
        case .search: toggleSearch(nil)
        case .quickOpen: toggleQuickOpen(nil)
        case .settings: NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
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

    /// While an overlay is open it keeps the keyboard: the panes
    /// beneath can still change (one gives way, an open finishes late), and
    /// the pane in focus gets the keyboard back when it closes.
    func applyPanes() {
        layoutView.panes = panes
        browserView.isPinned = panes.isPinned
        let focused: NSView = if let overlay = layoutView.overlay { overlay } else {
            switch panes.focus {
            case .browser: browserView
            case .editor: terminalView
            case .preview: previewView
            }
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
            askToDelete(path)
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

    // MARK: - Colors

    /// nvim reported its colors (at startup, or after its colorscheme or
    /// background changed): every pane takes them, and the report is
    /// remembered for the next launch.
    func receiveColors(_ report: NvimColors) {
        apply(theme: themeBase.theme(nvim: report))
        guard report != savedColors else { return }
        lastColorsFile.save(report)
        savedColors = report
    }

    /// The one path that recolors the window while it's on screen: its
    /// background and title bar (whose text and controls follow the
    /// background's brightness), the cover, the dividers, the browser, the
    /// overlays (open, or kept for reopening) and the preview. A theme equal
    /// to the current one changes nothing.
    func apply(theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        window?.backgroundColor = theme.background
        window?.appearance = theme.appearance
        editorContainer.coverColor = theme.background
        layoutView.dividerColor = theme.divider
        browserView.theme = theme
        searchView?.theme = theme
        quickOpenView?.theme = theme
        previewView.theme = theme
    }

    // MARK: - Files on disk

    /// `-` moved the browser: actions follow the new root, a prompt opened
    /// for the old one closes, and the next search or quick open lists the
    /// new root's files (an overlay has the keyboard while open, so none
    /// should be open now; one that is closes, as it shows the old root).
    private func browserRootChanged(_ root: String) {
        closePrompt()
        closeOverlay()
        fileActions = FileActions(root: root, fileSystem: LocalFileSystem())
        projectSearch = nil
        folderFiles = nil
        quickOpenFiles = nil
        quickOpenRanked = nil
        watch(root)
    }

    private func watch(_ root: String) {
        watcher?.stop()
        watcher = FolderWatcher(path: root) { [weak self] in
            guard let self else { return }
            browserView.reload()
            folderFiles?.invalidate()
            if isSearchOpen || isQuickOpenOpen { folderFiles?.prepare() }
            if case .viewOnly = previewState.target {
                if panes.isPreviewShown { previewView.reloadFromDisk() } else { isPreviewOutOfDate = true }
            }
        }
    }

    // MARK: - Window

    /// Closing on a running nvim asks first; "Close" saves nvim's side of
    /// the session before hanging up on it (a hang-up may not run nvim's own
    /// save on exit).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isNvimRunning else { return true }
        guard !isSavingBeforeClose else { return false }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "nvim is still running. Any unsaved changes will be lost."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            isSavingBeforeClose = true
            Task {
                await self.saveSession()
                self.isSavingBeforeClose = false
                // nvim may have exited meanwhile, closing the window.
                guard !self.isClosing else { return }
                self.isNvimRunning = false
                sender.close()
            }
        }
        return false
    }

    func windowWillEnterFullScreen(_: Notification) {
        frameBeforeFullScreen = window?.frame
    }

    func windowDidExitFullScreen(_: Notification) {
        frameBeforeFullScreen = nil
    }

    /// However the window closes, its side of the session is saved, and
    /// another window may then keep the folder's nvim session.
    func windowWillClose(_: Notification) {
        isClosing = true
        saveWindowSide()
        sessionLock.release()
        watcher?.stop()
        stopSearch()
        stopQuickOpen()
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
/// Cmd+2, Cmd+[, Cmd+], Cmd+Shift+F, Cmd+Shift+O, Cmd+,) before the terminal
/// sees them: Ghostty binds Cmd+digit to tabs, Cmd+[ / Cmd+] to splits, neither
/// of which scwrote has, and Cmd+, to opening its own config.
@MainActor
final class EditorWindow: NSWindow {
    var onShortcut: ((WindowShortcut) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let shortcut = WindowShortcut(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: Self.modifiers(of: event)) {
            onShortcut?(shortcut)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func modifiers(of event: NSEvent) -> WindowShortcut.Modifiers {
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

/// Keeps the terminal filling its pane and its grid sized to match, and can
/// hold it blank under a cover while nvim's side of a session loads.
@MainActor
final class TerminalContainerView: NSView {
    private let terminalView: TerminalView
    private let cover: CoverView

    /// Shows a plain view in the theme's background over the terminal. It
    /// never takes the keyboard or clicks: those still reach the terminal.
    var isCovered: Bool {
        get { !cover.isHidden }
        set { cover.isHidden = !newValue }
    }

    /// The cover's color: the theme's background.
    var coverColor: NSColor {
        get { cover.color }
        set { cover.color = newValue }
    }

    init(terminalView: TerminalView, background: NSColor) {
        self.terminalView = terminalView
        cover = CoverView(color: background)
        super.init(frame: .zero)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        cover.isHidden = true
        cover.autoresizingMask = [.width, .height]
        cover.frame = bounds
        addSubview(cover) // above the terminal
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        terminalView.fitToSize()
    }

    /// Layer-backed, so it stays above the terminal's Metal layer.
    private final class CoverView: NSView {
        var color: NSColor {
            didSet { layer?.backgroundColor = color.cgColor }
        }

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = color.cgColor
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }
}
