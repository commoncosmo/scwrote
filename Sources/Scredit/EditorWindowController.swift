import AppKit
import GhosttyTerminal
import ScreditCore

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
    private let nvimQueue = DispatchQueue(label: "scredit.nvim")
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
        window.onToggleBrowser = { [weak self] in self?.toggleFileBrowser(nil) }
        window.onTogglePin = { [weak self] in self?.toggleFileBrowserPin(nil) }

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
        listenForNvim(socketPath: nvimSocket)
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
                FileHandle.standardError.write(Data("scredit: couldn't open \(path) in nvim: \(error)\n".utf8))
            }
        }
    }

    private func revealCurrentFile() {
        Task {
            guard let file = try? await nvimCall({ try $0.currentFile() }) else { return }
            browserView.reveal(file)
        }
    }

    /// Adds nvim's Ctrl-w mappings and waits for them to ask for the browser,
    /// on a connection and thread of their own, for as long as nvim runs.
    private func listenForNvim(socketPath: String) {
        let events = NvimClient(socketPath: socketPath, connectTimeout: 10)
        let focusBrowser: @MainActor @Sendable () -> Void = { [weak self] in
            self?.change { $0.focusBrowser() }
        }
        let thread = Thread {
            do {
                try events.installPaneMappings()
                while let notification = try events.nextNotification() {
                    guard notification == NvimPaneMappings.browserRequest else { continue }
                    Task { @MainActor in focusBrowser() }
                }
            } catch NvimClient.Failure.connectionLost {
                // nvim exited; the window closes with it.
            } catch {
                FileHandle.standardError.write(Data("scredit: no Ctrl-w to the file browser: \(error)\n".utf8))
            }
        }
        thread.name = "scredit.nvim-events"
        thread.start()
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

/// Catches Cmd+1 and Cmd+Shift+1 before the terminal sees them (Ghostty binds
/// Cmd+digit to tab switching).
@MainActor
final class EditorWindow: NSWindow {
    var onToggleBrowser: (() -> Void)?
    var onTogglePin: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 18 { // the 1 key
            if flags == .command {
                onToggleBrowser?()
                return true
            }
            if flags == [.command, .shift] {
                onTogglePin?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
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
