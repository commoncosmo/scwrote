import AppKit
import ScreditCore

/// Lays out the file browser and the editor for a `PaneLayout.Mode`, with a
/// draggable divider between them.
///
/// In browser-only mode the browser covers the editor instead of replacing
/// it: the terminal keeps its full size underneath, so nvim runs normally and
/// is ready the moment a file is opened.
@MainActor
final class EditorLayoutView: NSView {
    let browserView: FileBrowserView
    let editorView: NSView

    var mode: PaneLayout.Mode = .editorOnly {
        didSet {
            browserView.isHidden = mode == .editorOnly
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var dividerColor: NSColor { didSet { needsDisplay = true } }
    private var browserWidth: CGFloat = 280
    private var isDragging = false
    private let grabWidth: CGFloat = 4

    init(browserView: FileBrowserView, editorView: NSView, dividerColor: NSColor) {
        self.browserView = browserView
        self.editorView = editorView
        self.dividerColor = dividerColor
        super.init(frame: .zero)
        addSubview(editorView)
        addSubview(browserView) // on top, for browser-only mode
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keeps both panes usable: at least 160 points each.
    private var clampedBrowserWidth: CGFloat {
        min(max(browserWidth, 160), max(bounds.width - 160, 160))
    }

    override func layout() {
        super.layout()
        switch mode {
        case .editorOnly:
            editorView.frame = bounds
        case .browserOnly:
            editorView.frame = bounds
            browserView.frame = bounds
        case .split:
            let width = clampedBrowserWidth
            browserView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            editorView.frame = NSRect(x: width + 1, y: 0, width: bounds.width - width - 1, height: bounds.height)
        }
    }

    override func draw(_: NSRect) {
        guard mode == .split else { return }
        dividerColor.setFill()
        NSRect(x: clampedBrowserWidth, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: - Dragging the divider

    private var grabZone: NSRect {
        NSRect(x: clampedBrowserWidth - grabWidth, y: 0, width: grabWidth * 2 + 1, height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if mode == .split, grabZone.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if mode == .split { addCursorRect(grabZone, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = mode == .split
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        browserWidth = convert(event.locationInWindow, from: nil).x
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with _: NSEvent) {
        isDragging = false
    }
}
