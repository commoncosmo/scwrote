import AppKit
import GhosttyTerminal
import ScreditCore

/// One window: a Ghostty terminal surface running nvim.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// True until nvim exits. Closing the window while it runs hangs up on it.
    private(set) var isNvimRunning = true

    private let terminalView = TerminalView(frame: .zero)

    /// `controller` carries the nvim command in its config (see
    /// `GhosttyConfig.editorConfig` for why it isn't a surface option).
    init(request: LaunchRequest, controller: TerminalController) {
        let window = NSWindow(
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
        window.backgroundColor = NSColor(controller.backgroundColor)
        window.contentMinSize = NSSize(width: 320, height: 200)
        super.init(window: window)
        window.delegate = self

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: request.workingDirectory
        )
        terminalView.controller = controller
        window.contentView = TerminalContainerView(terminalView: terminalView)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(terminalView)
    }

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
        onClose?()
    }
}

extension EditorWindowController: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    func terminalDidChangeTitle(_ title: String) {
        window?.title = title
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

/// Keeps the terminal filling the window and its grid sized to match.
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

private extension NSColor {
    convenience init(_ color: TerminalColor) {
        self.init(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
