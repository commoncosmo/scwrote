import AppKit
import ScwroteCore

/// Lays out the file browser, the editor and the preview for a `PaneLayout`
/// (browser | editor | preview, spans from `PaneFrames`), with a draggable
/// divider beside each side pane.
///
/// In browser-only mode the browser covers the editor instead of replacing
/// it: the terminal keeps its full size underneath, so nvim runs normally and
/// is ready the moment a file is opened.
@MainActor
final class EditorLayoutView: NSView {
    let browserView: FileBrowserView
    let editorView: NSView
    let previewView: PreviewPaneView

    /// Named `panes`, not `layout`, which is NSView's layout pass.
    var panes: PaneLayout {
        // Focus counts too: the pane with the keyboard never gives way.
        didSet { if panes != oldValue { needsLayout = true } }
    }

    /// After a layout in which the set of panes squeezed out for lack of room
    /// changed: the new set.
    var onGaveWay: ((Set<PaneLayout.Pane>) -> Void)?

    var dividerColor: NSColor { didSet { needsDisplay = true } }
    /// A view over all the panes (the search overlay), or nil. The panes stay
    /// as they are beneath it, and its clicks never grab a divider.
    var overlay: NSView? {
        didSet {
            guard overlay !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let overlay {
                overlay.frame = bounds
                addSubview(overlay)
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The side panes' widths as last set by dragging their dividers (or
    /// restored); `PaneFrames` applies the minimums when laying out.
    var browserWidth = CGFloat(PaneFrames.defaultBrowserWidth) {
        didSet { if browserWidth != oldValue { needsLayout = true } }
    }
    var previewWidth = CGFloat(PaneFrames.defaultPreviewWidth) {
        didSet { if previewWidth != oldValue { needsLayout = true } }
    }
    private var frames: PaneFrames?
    private var dragging: PaneLayout.Pane?
    private let grabWidth: CGFloat = 4

    init(browserView: FileBrowserView, editorView: NSView, previewView: PreviewPaneView, panes: PaneLayout, dividerColor: NSColor) {
        self.browserView = browserView
        self.editorView = editorView
        self.previewView = previewView
        self.panes = panes
        self.dividerColor = dividerColor
        super.init(frame: .zero)
        addSubview(editorView)
        addSubview(browserView) // on top, for browser-only mode
        addSubview(previewView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The panes `panes` would squeeze out at the current size. Empty before
    /// the view has a size.
    func gaveWay(for panes: PaneLayout) -> Set<PaneLayout.Pane> {
        bounds.width > 0 ? frames(for: panes).gaveWay : []
    }

    private func frames(for panes: PaneLayout) -> PaneFrames {
        PaneFrames.compute(
            panes, totalWidth: Double(bounds.width),
            browserWidth: Double(browserWidth), previewWidth: Double(previewWidth)
        )
    }

    override func layout() {
        super.layout()
        let frames = frames(for: panes)
        let previous = self.frames
        self.frames = frames

        editorView.frame = panes.mode == .browserOnly ? bounds : rect(frames.editor)
        browserView.isHidden = frames.browser == nil
        if let browser = frames.browser { browserView.frame = rect(browser) }
        previewView.isHidden = frames.preview == nil
        if let preview = frames.preview { previewView.frame = rect(preview) }
        overlay?.frame = bounds
        if frames != previous {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        if frames.gaveWay != (previous?.gaveWay ?? []) { onGaveWay?(frames.gaveWay) }
    }

    private func rect(_ span: PaneFrames.Span) -> NSRect {
        NSRect(x: span.x, y: 0, width: span.width, height: Double(bounds.height))
    }

    // MARK: - Dividers

    /// The one-point lines between panes, each with the side pane it resizes.
    private var dividers: [(pane: PaneLayout.Pane, rect: NSRect)] {
        guard let frames else { return [] }
        var dividers: [(PaneLayout.Pane, NSRect)] = []
        if panes.mode == .split, let browser = frames.browser {
            dividers.append((.browser, NSRect(x: browser.x + browser.width, y: 0, width: PaneFrames.divider, height: Double(bounds.height))))
        }
        if let preview = frames.preview {
            dividers.append((.preview, NSRect(x: preview.x - PaneFrames.divider, y: 0, width: PaneFrames.divider, height: Double(bounds.height))))
        }
        return dividers
    }

    /// Where the dividers are drawn, for the debug snapshot.
    var dividerRects: [NSRect] { dividers.map(\.rect) }

    override func draw(_: NSRect) {
        dividerColor.setFill()
        for divider in dividers { divider.rect.fill() }
    }

    // MARK: - Dragging the dividers

    private func grabZone(_ divider: NSRect) -> NSRect {
        divider.insetBy(dx: -grabWidth, dy: 0)
    }

    private func divider(at point: NSPoint) -> PaneLayout.Pane? {
        dividers.first { grabZone($0.rect).contains(point) }?.pane
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if overlay == nil, divider(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard overlay == nil else { return }
        for divider in dividers { addCursorRect(grabZone(divider.rect), cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = divider(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        // Within the window; PaneFrames applies the minimums.
        let x = min(max(convert(event.locationInWindow, from: nil).x, 0), bounds.width)
        switch dragging {
        case .browser: browserWidth = x
        case .preview: previewWidth = bounds.width - x
        case .editor: return
        }
        needsLayout = true
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        dragging = nil
    }
}
