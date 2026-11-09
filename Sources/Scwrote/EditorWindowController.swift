import AppKit
import GhosttyTerminal
import ScwroteCore

/// One window: the file browser and a Ghostty terminal surface running nvim,
/// shown according to `PaneLayout`.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// True until nvim exits. Closing the window while it runs hangs up on it.
    private(set) var isNvimRunning = true

    let terminalView = EditorTerminalView(frame: .zero)
    let browserView: FileBrowserView
    let layoutView: EditorLayoutView
    private(set) var panes: PaneLayout

    /// nvim's RPC socket. Calls block, so they run on `nvimQueue`.
    private let nvim: NvimClient
    private let nvimQueue = DispatchQueue(label: "scwrote.nvim")
    private var watcher: FolderWatcher?

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
        layoutView = EditorLayoutView(
            browserView: browserView,
            editorView: TerminalContainerView(terminalView: terminalView),
            dividerColor: theme.divider
        )
        panes = PaneLayout(startsInBrowser: request.startsInBrowser)
        nvim = NvimClient(socketPath: nvimSocket)
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
        browserView.onRootChange = { [weak self] in self?.watch($0) }

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
        change { $0.toggleBrowser() }
    }

    /// Cmd+Shift+1 (View menu).
    @objc func toggleFileBrowserPin(_: Any?) {
        change { $0.togglePin() }
    }

    /// Cmd+[ (View menu): go to the browser, showing it if hidden.
    @objc func goToFileBrowser(_: Any?) {
        change { $0.focusBrowser() }
    }

    /// Cmd+] (View menu): go to the editor, hiding the browser unless pinned.
    @objc func goToEditor(_: Any?) {
        change { $0.leaveBrowser() }
    }

    private func perform(_ shortcut: WindowShortcut) {
        switch shortcut {
        case .toggleBrowser: toggleFileBrowser(nil)
        case .toggleBrowserPin: toggleFileBrowserPin(nil)
        case .goToBrowser: goToFileBrowser(nil)
        case .goToEditor: goToEditor(nil)
        }
    }

    /// Applies a layout change. A browser that just appeared opens on the file
    /// being edited.
    func change(_ update: (inout PaneLayout) -> Void) {
        let wasHidden = panes.mode == .editorOnly
        update(&panes)
        applyPanes()
        if wasHidden, panes.mode != .editorOnly { revealCurrentFile() }
    }

    private func applyPanes() {
        layoutView.mode = panes.mode
        browserView.isPinned = panes.isPinned
        let focused: NSView = panes.focus == .browser ? browserView : terminalView
        if window?.firstResponder !== focused { window?.makeFirstResponder(focused) }
    }

    private func handle(_ action: BrowserAction) {
        switch action {
        case .leave: change { $0.leaveBrowser() }
        case let .open(path): open(path)
        }
    }

    // MARK: - nvim

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

    private func nvimCall<T: Sendable>(_ work: @escaping @Sendable (NvimClient) throws -> T) async throws -> T {
        let nvim = nvim
        return try await withCheckedThrowingContinuation { continuation in
            nvimQueue.async { continuation.resume(with: Result { try work(nvim) }) }
        }
    }

    // MARK: - Files on disk

    private func watch(_ root: String) {
        watcher?.stop()
        watcher = FolderWatcher(path: root) { [weak self] in self?.browserView.reload() }
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
        watcher?.stop()
        onClose?()
    }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFileBrowserPin(_:)) {
            item.title = panes.isPinned ? "Unpin File Browser" : "Pin File Browser"
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
/// Cmd+[, Cmd+]) before the terminal sees them: Ghostty binds Cmd+digit to
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
