import AppKit
import PDFKit
import ScwroteCore
import WebKit

/// The preview pane: a header row over a body that shows the target the way
/// its kind needs. Markdown, tables, diagrams and trees render in scwrote's
/// own page, HTML in a web view with its scripts off, images and PDFs in
/// AppKit views. The pane takes the keyboard itself and reads vim keys.
@MainActor
final class PreviewPaneView: NSView, NSGestureRecognizerDelegate {
    /// Esc: back to the editor.
    var onLeave: (() -> Void)?
    /// The user clicked into the pane.
    var onClick: (() -> Void)?
    /// A local path clicked in a markdown or HTML preview.
    var onOpenLink: ((String) -> Void)?
    /// After every `show`: the renderer's error or note for what is shown.
    var onRendered: ((_ error: String?, _ note: String?) -> Void)?

    private enum Body { case empty, document, html, image, pdf }

    private let theme: Theme
    private let schemeHandler: PreviewSchemeHandler
    private let headerView: PreviewHeaderView
    private let documentView: PreviewDocumentWebView
    private var htmlView: PreviewHTMLWebView?
    private var imageView: PreviewImageScrollView?
    private var pdfView: PDFView?
    private let unsavedStripe: FillView
    private var body = Body.empty
    /// What `show` was last given.
    private var state = PreviewState()
    /// Counts `show` calls; an image or PDF read for an older one is dropped.
    private var generation = 0
    private var keyReader = PreviewKeyReader()
    /// The paths whose contents the image and PDF views hold.
    private var imagePath: String?
    private var pdfPath: String?

    init(theme: Theme) {
        self.theme = theme
        schemeHandler = PreviewSchemeHandler(
            appResources: Bundle.module.resourceURL!.appending(path: "Preview")
        )
        headerView = PreviewHeaderView(theme: theme)
        documentView = PreviewDocumentWebView(
            schemeHandler: schemeHandler, theme: Self.pageTheme(theme), background: theme.background
        )
        unsavedStripe = FillView(color: theme.warning)
        super.init(frame: .zero)

        documentView.isHidden = true
        documentView.onOpenFile = { [weak self] in self?.onOpenLink?($0) }
        documentView.onRendered = { [weak self] in self?.onRendered?($0, $1) }
        unsavedStripe.isHidden = true
        addSubview(headerView)
        addSubview(documentView)
        addSubview(unsavedStripe)

        // Clicks anywhere in the pane, the web views' and PDF view's included,
        // move the keyboard here without taking the click from them.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delegate = self
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Showing

    /// Shows the header and renders the body for the state's target and kind.
    /// Ends in exactly one `onRendered`.
    func show(_ state: PreviewState) {
        self.state = state
        generation += 1
        keyReader = PreviewKeyReader()
        showHeader(state.header)

        var snapshot: BufferSnapshot?
        var path: String?
        switch state.target {
        case .none: break
        case let .buffer(buffer):
            snapshot = buffer
            path = buffer.path
        case let .viewOnly(viewOnly):
            path = viewOnly
        }
        let kind = state.kind
        if kind != .html { schemeHandler.overlay = nil }

        if let snapshot, snapshot.text == nil, !kind.isViewOnly {
            // Too large (the state's own message, "too large to preview",
            // stays), or a file with no preview, which was sent without text.
            setBody(.empty)
            onRendered?(nil, state.header.message)
            return
        }
        switch (kind, path) {
        case let (_, path?) where kind.rendersInPage:
            guard let snapshot, let text = snapshot.text else { return showEmpty() }
            setBody(.document)
            documentView.render([
                "kind": kind.rawValue,
                "text": text,
                "baseURL": PreviewURL.folder(of: path).absoluteString,
                "cursor": ["line": snapshot.cursor.line, "column": snapshot.cursor.column],
            ])
        case let (.html, path?):
            schemeHandler.overlay = snapshot?.text.map { (path: path, text: $0) }
            let fraction = snapshot.map { Self.fraction(of: $0.cursor, lineCount: $0.lineCount) } ?? 0
            setBody(.html)
            html().show(PreviewURL.file(path), scrolledTo: fraction)
            onRendered?(nil, nil)
        case let (.image, path?):
            setBody(.image)
            showImage(at: path)
        case let (.pdf, path?):
            setBody(.pdf)
            showPDF(at: path)
        default:
            showEmpty()
        }
    }

    func showHeader(_ header: PreviewHeader) {
        headerView.header = header
        unsavedStripe.isHidden = !header.isUnsaved
    }

    /// Scrolls to the editor's cursor: the renderer maps it to a block, HTML
    /// scrolls in proportion to the line.
    func follow(_ cursor: CursorPosition, lineCount: Int) {
        switch body {
        case .document: documentView.follow(cursor)
        case .html: htmlView?.scroll(toFraction: Self.fraction(of: cursor, lineCount: lineCount))
        case .empty, .image, .pdf: break
        }
    }

    /// The shown image or PDF changed on disk.
    func reloadFromDisk() {
        if state.kind.isViewOnly { show(state) }
    }

    private func showEmpty() {
        setBody(.empty)
        onRendered?(nil, nil)
    }

    private func setBody(_ new: Body) {
        if body == .document, new != .document { documentView.deactivate() }
        body = new
        documentView.isHidden = new != .document
        htmlView?.isHidden = new != .html
        imageView?.isHidden = new != .image
        pdfView?.isHidden = new != .pdf
    }

    /// How far down the cursor's line is, from 0 (first line) to 1 (last).
    private static func fraction(of cursor: CursorPosition, lineCount: Int) -> Double {
        min(max(Double(cursor.line - 1) / Double(max(lineCount - 1, 1)), 0), 1)
    }

    // MARK: - Images and PDFs

    private func showImage(at path: String) {
        let view = image()
        if imagePath != path {
            view.image = nil
            imagePath = nil
        }
        read(path) { [weak self] data in
            guard let self else { return }
            if let data, let image = NSImage(data: data) {
                view.image = image
                imagePath = path
                onRendered?(nil, nil)
            } else {
                // A file being rewritten keeps its last good image.
                onRendered?("cannot read image", nil)
            }
        }
    }

    private func showPDF(at path: String) {
        let view = pdf()
        if pdfPath != path {
            view.document = nil
            pdfPath = nil
        }
        read(path) { [weak self] data in
            guard let self else { return }
            if let data, let document = PDFDocument(data: data) {
                view.document = document
                pdfPath = path
                onRendered?(nil, nil)
            } else {
                onRendered?("cannot read PDF", nil)
            }
        }
    }

    /// Reads a file off the main thread; `done` runs only if no newer `show` came.
    private func read(_ path: String, done: @escaping (Data?) -> Void) {
        let call = generation
        Task {
            let data = await Self.contents(of: path)
            if call == generation { done(data) }
        }
    }

    @concurrent
    private nonisolated static func contents(of path: String) async -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Body views, made when first needed

    private func html() -> PreviewHTMLWebView {
        if let htmlView { return htmlView }
        let view = PreviewHTMLWebView(schemeHandler: schemeHandler, background: theme.background)
        view.onOpenFile = { [weak self] in self?.onOpenLink?($0) }
        addBody(view)
        htmlView = view
        return view
    }

    private func image() -> PreviewImageScrollView {
        if let imageView { return imageView }
        let view = PreviewImageScrollView(background: theme.background)
        addBody(view)
        imageView = view
        return view
    }

    private func pdf() -> PDFView {
        if let pdfView { return pdfView }
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = theme.background
        addBody(view)
        pdfView = view
        return view
    }

    private func addBody(_ view: NSView) {
        view.frame = bodyFrame
        addSubview(view, positioned: .below, relativeTo: unsavedStripe)
    }

    // MARK: - Layout and drawing

    private var bodyFrame: NSRect {
        let top = headerView.preferredHeight
        return NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
    }

    override func layout() {
        super.layout()
        headerView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerView.preferredHeight)
        for view in [documentView, htmlView, imageView, pdfView] as [NSView?] {
            view?.frame = bodyFrame
        }
        unsavedStripe.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
    }

    override func draw(_: NSRect) {
        theme.background.setFill()
        bounds.fill()
    }

    /// The pane as drawn. Web views are captured through their own snapshot
    /// API and PDF pages drawn afresh (view caching misses both), everything
    /// else through ordinary view caching.
    func snapshot() async -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let webView: WKWebView? = switch body {
        case .document: documentView
        case .html: htmlView
        case .empty, .image, .pdf: nil
        }
        let shot = if let webView { try? await webView.takeSnapshot(configuration: nil) } else { NSImage?.none }
        if shot != nil || body == .pdf {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if let webView, let shot { shot.draw(in: unflipped(webView.frame)) }
            if body == .pdf, let pdfView { drawPages(of: pdfView) }
            if !unsavedStripe.isHidden {
                theme.warning.setFill()
                NSRect(x: 0, y: 0, width: unsavedStripe.frame.width, height: bounds.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// A rect in the pane, in the snapshot's coordinates: the pane is
    /// flipped, the bitmap's origin is bottom-left.
    private func unflipped(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Draws the PDF view's visible pages where it shows them, into the
    /// current graphics context.
    private func drawPages(of view: PDFView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: unflipped(view.frame))
        for page in view.visiblePages {
            let box = page.bounds(for: view.displayBox)
            let target = unflipped(convert(view.convert(box, from: page), from: view))
            guard box.width > 0, box.height > 0 else { continue }
            context.saveGState()
            context.translateBy(x: target.minX, y: target.minY)
            context.scaleBy(x: target.width / box.width, y: target.height / box.height)
            page.draw(with: view.displayBox, to: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    // MARK: - Mouse and keyboard

    @objc private func clicked() {
        onClick?()
        window?.makeFirstResponder(self)
    }

    func gestureRecognizer(
        _: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith _: NSGestureRecognizer
    ) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard let key = FileBrowserView.browserKey(for: event) else {
            super.keyDown(with: event)
            return
        }
        guard let command = keyReader.read(key) else { return }
        if command == .leave {
            onLeave?()
            return
        }
        switch body {
        case .document: documentView.command(Self.pageName(of: command))
        case .html: htmlView?.command(command)
        case .image: imageView?.scroll(for: command, line: lineHeight)
        case .pdf: pdfView?.documentView?.enclosingScrollView?.scroll(for: command, line: lineHeight)
        case .empty: break
        }
    }

    /// One line, as the renderer page scrolls it.
    private var lineHeight: CGFloat { 1.5 * theme.font.pointSize }

    /// The command's name in the page's `scwrote.command`.
    private static func pageName(of command: PreviewCommand) -> String {
        switch command {
        case .lineDown: "lineDown"
        case .lineUp: "lineUp"
        case .halfPageDown: "halfPageDown"
        case .halfPageUp: "halfPageUp"
        case .top: "top"
        case .bottom: "bottom"
        case .open: "open"
        case .close: "close"
        case .toggle: "toggle"
        case .leave: "leave"
        }
    }

    // MARK: - Theme

    /// The page's `setTheme` argument, in the Ghostty theme's colors and font.
    private static func pageTheme(_ theme: Theme) -> [String: Any] {
        let background = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let luminance = 0.2126 * background.redComponent + 0.7152 * background.greenComponent
            + 0.0722 * background.blueComponent
        return [
            "background": Theme.css(theme.background),
            "foreground": Theme.css(theme.foreground),
            "dim": Theme.css(theme.dim),
            "selection": Theme.css(theme.selection),
            "accent": Theme.css(theme.folder),
            "warning": Theme.css(theme.warning),
            "divider": Theme.css(theme.divider),
            "fontFamily": theme.font.familyName ?? "monospace",
            "fontSize": Double(theme.font.pointSize),
            "isDark": luminance < 0.5,
        ]
    }
}

/// An image at its own size, or scaled down to the pane's width (never up);
/// a tall one scrolls.
@MainActor
final class PreviewImageScrollView: NSScrollView {
    private let imageView = NSImageView()

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            layoutImage()
        }
    }

    init(background: NSColor) {
        super.init(frame: .zero)
        backgroundColor = background
        drawsBackground = true
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let document = FlippedView()
        document.addSubview(imageView)
        documentView = document
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tile() {
        super.tile()
        layoutImage()
    }

    private func layoutImage() {
        let visible = contentSize
        var size = imageView.image?.size ?? .zero
        if size.width > visible.width, size.width > 0 {
            size = NSSize(width: visible.width, height: size.height * visible.width / size.width)
        }
        documentView?.frame = NSRect(x: 0, y: 0, width: visible.width, height: max(size.height, visible.height))
        imageView.frame = NSRect(x: ((visible.width - size.width) / 2).rounded(), y: 0, width: size.width, height: size.height)
    }
}

extension NSScrollView {
    /// Scrolls for a preview key; `line` is one line's height.
    func scroll(for command: PreviewCommand, line: CGFloat) {
        guard let document = documentView else { return }
        let clip = contentView
        let visible = clip.bounds
        let frame = document.frame
        let range = max(frame.height - visible.height, 0)
        // How far below the top the view is scrolled.
        let offset = document.isFlipped ? visible.minY - frame.minY : frame.maxY - visible.maxY
        let target: CGFloat
        switch command {
        case .lineDown: target = offset + line
        case .lineUp: target = offset - line
        case .halfPageDown: target = offset + visible.height / 2
        case .halfPageUp: target = offset - visible.height / 2
        case .top: target = 0
        case .bottom: target = range
        case .open, .close, .toggle, .leave: return
        }
        let clamped = min(max(target, 0), range)
        let y = document.isFlipped ? frame.minY + clamped : frame.maxY - visible.height - clamped
        clip.scroll(to: NSPoint(x: visible.minX, y: y))
        reflectScrolledClipView(clip)
    }
}

/// A plain rectangle of one color; drawn (not a layer) so it shows in snapshots.
@MainActor
private final class FillView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
