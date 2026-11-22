import AppKit
import ScwroteCore

/// Takes overlay keys as the keyboard would send them: the debug hooks use
/// it to reach whichever overlay is open.
@MainActor
protocol OverlayKeyTarget: AnyObject {
    func press(_ key: SearchKey)
}

/// The overlays (Cmd+Shift+F's search, Cmd+Shift+O's quick open), drawn like
/// the file browser (the theme's font and colors): the query with the count
/// beside it, the result rows, a preview of the selected one and the key
/// hints. `Renderer` draws the rows and says what to preview and which hints
/// to show. It covers the whole window, clear outside its panel, so a click
/// anywhere outside the panel closes it.
@MainActor
final class ListOverlayView<Renderer: OverlayRenderer>: NSView, OverlayKeyTarget {
    private(set) var overlay = SearchOverlay<Renderer.List>()
    let theme: Theme
    /// The searched folder, resolved like the results' paths, which show
    /// relative to it.
    var root = "" { didSet { needsDisplay = true } }
    /// No ripgrep was found: the panel says how to get one, and nothing else.
    var isMissingRipgrep = false { didSet { needsDisplay = true } }
    /// Unsaved buffers' text by path. The preview shows these rather than
    /// what's on disk.
    var unsaved: [String: String] = [:] {
        didSet {
            previewFiles.removeAll()
            needsDisplay = true
        }
    }

    var results: Renderer.List {
        get { overlay.results }
        set {
            overlay.results = newValue
            scrollToSelection()
        }
    }

    /// The query changed, a result was chosen, hidden files were toggled, or
    /// the overlay asked to close.
    var onAction: ((SearchAction<Renderer.List.Item>) -> Void)?

    /// Shown in place of the count while the owner works on the overlay's
    /// behalf (search sending its matches to quickfix). Meanwhile Esc calls
    /// `onCancelBusy` and other keys, paste and the mouse do nothing.
    var busyMessage: String? { didSet { needsDisplay = true } }
    var onCancelBusy: (() -> Void)?

    private let renderer = Renderer()
    /// Files as the preview shows them, read once per opening (see
    /// `reopen()`); a file read only for its first lines is read again in
    /// full when a line deeper in it is wanted.
    private var previewFiles: [String: PreviewFile] = [:]
    /// First result row drawn; scrolls to keep the selection in view.
    private var topRow = 0
    /// Scrolling not yet worth a whole row, in rows.
    private var scrollRemainder: CGFloat = 0

    private let padding: CGFloat = 10
    private let tab = "    "
    /// Long lines are cut here before drawing; the preview clips them anyway.
    private let previewColumns = 400
    /// Larger files aren't previewed: they're read on the main thread while
    /// drawing, and a huge log would stall typing. With no line to center
    /// on, only the file's start is read (see `PreviewFile.read`).
    private let previewByteLimit = 8 * 1024 * 1024

    private var style: OverlayStyle { OverlayStyle(theme: theme) }
    private var gap: CGFloat { style.gap }

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        // Over the terminal's Metal layer.
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Opened again: the last query comes back selected, and files are read
    /// afresh for the preview.
    func reopen() {
        overlay.reopen()
        previewFiles.removeAll()
        needsDisplay = true
    }

    /// A key, as the keyboard would send it (also for the debug hooks).
    /// Without ripgrep only Esc means anything: it closes.
    func press(_ key: SearchKey) {
        if busyMessage != nil {
            if key == .escape { onCancelBusy?() }
            return
        }
        if isMissingRipgrep {
            if key == .escape { onAction?(.close) }
            return
        }
        send(overlay.handle(key, pageHeight: frames.rows))
    }

    private func send(_ action: SearchAction<Renderer.List.Item>?) {
        scrollToSelection()
        if let action { onAction?(action) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let key = Self.searchKey(for: event) else { return }
        // A held Esc or Enter acts once: a repeat would close the list it
        // just switched to, or open the result again.
        if event.isARepeat, key == .escape || key == .enter { return }
        press(key)
    }

    /// There's no Edit menu (Cmd+V is the terminal's), so paste is handled
    /// here: into the query while typing, nowhere in the list. Cmd+Shift+.
    /// shows or hides hidden files, for a renderer that lists them; held
    /// down, it acts once, so the files don't flicker in and out.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            if !isMissingRipgrep, busyMessage == nil, overlay.mode == .typing {
                send(overlay.paste(NSPasteboard.general.string(forType: .string) ?? ""))
            }
            return true
        }
        if Renderer.togglesHidden,
           OverlayShortcut.isHiddenFilesToggle(keyCode: event.keyCode, modifiers: EditorWindow.modifiers(of: event)) {
            if !isMissingRipgrep, busyMessage == nil, !event.isARepeat { send(overlay.toggleHidden()) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Ctrl-J / Ctrl-K and the arrows move, Ctrl-D / Ctrl-U page, and the
    /// rest are the browser prompt's editing keys. Cmd combinations are left
    /// to the window and menu.
    static func searchKey(for event: NSEvent) -> SearchKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return nil }
        switch event.keyCode {
        case 125: return .next
        case 126: return .previous
        case 36, 76: return .enter
        case 53: return .escape
        default: break
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "j": return .next
            case "k": return .previous
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            case "q": return .sendToQuickfix
            default: break
            }
        }
        switch FileBrowserView.promptKey(for: event) {
        case let .character(character)?: return .character(character)
        case let key?: return .edit(key)
        case nil: return nil
        }
    }

    // MARK: - Mouse

    /// A click selects a row, a double-click opens it, and a click outside
    /// the panel closes the overlay.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard busyMessage == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frames = frames
        guard frames.panel.contains(point) else {
            onAction?(.close)
            return
        }
        guard !isMissingRipgrep, frames.list.contains(point), let current = results.selectedIndex else { return }
        let row = topRow + Int((point.y - frames.list.minY) / lineHeight)
        guard row < results.count else { return }
        overlay.results.move(by: row - current)
        needsDisplay = true
        if event.clickCount == 2 { press(.enter) }
    }

    /// Scrolling moves the selection a row at a time, so the list follows
    /// it as it does the keys.
    override func scrollWheel(with event: NSEvent) {
        guard !isMissingRipgrep, busyMessage == nil, results.count > 0 else { return }
        if event.phase == .began { scrollRemainder = 0 }
        // A trackpad reports points, a wheel lines; positive is toward the top.
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        let rows = Int(scrollRemainder.rounded(.towardZero))
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows)
        overlay.results.move(by: -rows)
        scrollToSelection()
    }

    // MARK: - Layout

    private var lineHeight: CGFloat {
        ceil(theme.font.ascender - theme.font.descender + theme.font.leading) + 4
    }

    /// Where each part goes: about 70% of the window each way, centered;
    /// the list above the preview, which gets the larger share.
    private struct Frames {
        var panel: NSRect
        var query: NSRect
        var list: NSRect
        var rows: Int
        var preview: NSRect
        var footer: NSRect
    }

    private var frames: Frames {
        let panel = bounds.insetBy(dx: (bounds.width * 0.15).rounded(), dy: (bounds.height * 0.15).rounded())
        let content = panel.insetBy(dx: padding, dy: padding)
        let query = NSRect(x: content.minX, y: content.minY, width: content.width, height: lineHeight + 8)
        if isMissingRipgrep {
            let short = NSRect(x: panel.minX, y: panel.minY, width: panel.width, height: query.height + padding * 2)
            return Frames(panel: short, query: query, list: .zero, rows: 0, preview: .zero, footer: .zero)
        }
        let footer = NSRect(x: content.minX, y: content.maxY - lineHeight, width: content.width, height: lineHeight)
        let middle = max(0, footer.minY - gap - query.maxY - gap * 2 - 1)
        // The preview's file name takes a line of its share.
        let lines = Int(middle / lineHeight)
        let rows = max(1, Int(Double(lines - 1) * 0.4))
        let list = NSRect(x: content.minX, y: query.maxY + gap, width: content.width, height: CGFloat(rows) * lineHeight)
        let previewTop = list.maxY + gap * 2 + 1
        let preview = NSRect(x: content.minX, y: previewTop, width: content.width, height: max(0, footer.minY - gap - previewTop))
        return Frames(panel: panel, query: query, list: list, rows: rows, preview: preview, footer: footer)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scrollToSelection()
    }

    private func scrollToSelection() {
        let rows = frames.rows
        if let selected = results.selectedIndex {
            if selected < topRow { topRow = selected } else if selected >= topRow + rows { topRow = selected - rows + 1 }
        }
        topRow = min(max(topRow, 0), max(results.count - rows, 0))
        needsDisplay = true
    }

    /// Rows and the count show once there's a query, or always for a
    /// renderer that lists an empty one.
    private var listsQuery: Bool {
        Renderer.listsEmptyQuery || !overlay.query.text.isEmpty
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        let frames = frames
        let style = style
        let panel = NSBezierPath(roundedRect: frames.panel, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 18
        shadow.set()
        theme.background.setFill()
        panel.fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.divider.setStroke()
        panel.stroke()

        if isMissingRipgrep {
            let message = style.attributed(Renderer.missingRipgrepMessage, color: theme.warning)
            style.draw(message, x: frames.query.minX, line: frames.query, width: frames.query.width)
            return
        }
        drawQuery(in: frames.query, style: style)
        drawRows(in: frames.list, rows: frames.rows, style: style)
        theme.divider.setFill()
        NSRect(x: frames.panel.minX, y: frames.list.maxY + gap, width: frames.panel.width, height: 1).fill()
        drawPreview(in: frames.preview, style: style)
        theme.divider.setFill()
        NSRect(x: frames.panel.minX, y: frames.footer.minY - gap / 2, width: frames.panel.width, height: 1).fill()
        let footer = style.attributed(renderer.footer(overlay.mode), color: theme.dim)
        style.draw(footer, x: frames.footer.minX, line: frames.footer, width: frames.footer.width)
    }

    /// The query in a field, the count at its right. While typing, a bar
    /// marks the cursor; a reopened query is drawn selected. Text too long
    /// for the field slides left so the cursor stays in view.
    private func drawQuery(in box: NSRect, style: OverlayStyle) {
        let field = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        theme.selectionInactive.setFill()
        field.fill()
        theme.divider.setStroke()
        field.stroke()

        let inner = box.insetBy(dx: 8, dy: 0)
        var available = inner.width
        let query = overlay.query
        if listsQuery {
            let count = style.attributed(busyMessage ?? results.countLine, color: theme.dim)
            let width = ceil(count.size().width)
            style.draw(count, x: inner.maxX - width, line: box, width: width)
            available -= width + gap * 2
        }

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: inner.minX, y: box.minY, width: max(available, 0), height: box.height).clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let beforeCursor = String(Array(query.text)[..<query.cursor])
        let cursorX = ceil(style.attributed(beforeCursor, color: theme.foreground).size().width)
        let x = inner.minX - max(0, cursorX + 2 - available)
        let text = style.attributed(query.text, color: theme.foreground, truncation: .byClipping)
        let textWidth = ceil(text.size().width)
        let glyphs = style.glyphRect(in: box)
        if overlay.isQuerySelected, !query.text.isEmpty {
            theme.selection.setFill()
            NSRect(x: x, y: glyphs.minY, width: textWidth, height: glyphs.height).fill()
        }
        style.draw(text, x: x, line: box, width: textWidth + 2)
        if overlay.mode == .typing, !overlay.isQuerySelected {
            theme.folder.setFill()
            NSRect(x: x + cursorX, y: glyphs.minY, width: 2, height: glyphs.height).fill()
        }
    }

    /// The visible rows, the selected one highlighted; the renderer draws
    /// each row's contents.
    private func drawRows(in list: NSRect, rows: Int, style: OverlayStyle) {
        guard listsQuery else { return }
        let results = results
        let selected = results.selectedIndex
        for index in topRow ..< min(results.count, topRow + rows) {
            let row = NSRect(x: list.minX, y: list.minY + CGFloat(index - topRow) * lineHeight, width: list.width, height: lineHeight)
            if index == selected {
                theme.selection.setFill()
                NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
            }
            renderer.drawRow(results[index], in: row.insetBy(dx: 6, dy: 0), root: root, style: style)
        }
    }

    /// The selected result's file: its name, then numbered lines, centered
    /// on the renderer's line (which is tinted) or from the top, with the
    /// renderer's highlights in the accent color. Tabs are 4 spaces; long
    /// lines are clipped. A binary or too-large file says so instead.
    private func drawPreview(in area: NSRect, style: OverlayStyle) {
        guard let item = results.selected, area.height >= lineHeight else { return }
        let preview = renderer.preview(of: item, query: overlay.query.text)
        let header = NSRect(x: area.minX, y: area.minY, width: area.width, height: lineHeight)
        let name = style.attributed((preview.path as NSString).lastPathComponent, color: theme.dim)
        style.draw(name, x: area.minX, line: header, width: area.width)

        let visible = Int((area.height - lineHeight) / lineHeight)
        guard visible > 0 else { return }
        let lines: [Substring]
        switch previewFile(for: preview.path, whole: preview.line != nil) {
        case let .text(text, _):
            lines = text
        case .binary:
            drawPreviewMessage("Binary file", below: header, style: style)
            return
        case .tooLarge:
            drawPreviewMessage("File too large to preview", below: header, style: style)
            return
        }
        guard !lines.isEmpty else { return }
        let first = preview.line.map { max(1, min($0 - visible / 2, lines.count - visible + 1)) } ?? 1
        let last = min(lines.count, first + visible - 1)
        let numberWidth = ceil(style.attributed(String(last), color: theme.dim).size().width)
        let textX = area.minX + 6 + numberWidth + gap

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        area.clip()
        for number in first ... last {
            let line = NSRect(x: area.minX, y: header.maxY + CGFloat(number - first) * lineHeight, width: area.width, height: lineHeight)
            if number == preview.line {
                theme.selectionInactive.setFill()
                NSBezierPath(roundedRect: line, xRadius: 4, yRadius: 4).fill()
            }
            let label = style.attributed(String(number), color: theme.dim)
            let labelWidth = ceil(label.size().width)
            style.draw(label, x: textX - gap - labelWidth, line: line, width: labelWidth)
            let content = lines[number - 1].prefix(previewColumns).replacingOccurrences(of: "\t", with: tab)
            let text = style.highlighted(
                style.attributed(content, color: theme.foreground, truncation: .byClipping), preview.highlights(content))
            style.draw(text, x: textX, line: line, width: area.maxX - textX)
        }
    }

    private func drawPreviewMessage(_ text: String, below header: NSRect, style: OverlayStyle) {
        let line = NSRect(x: header.minX, y: header.maxY, width: header.width, height: lineHeight)
        style.draw(style.attributed(text, color: theme.dim), x: line.minX + 6, line: line, width: line.width - 6)
    }

    /// The unsaved buffer's lines if there is one, else the file's: all of
    /// it when `whole` (to center on a line), else its start. Read once per
    /// opening, and again in full if only the start was read before.
    private func previewFile(for path: String, whole: Bool) -> PreviewFile {
        if let known = previewFiles[path], !(whole && known.isPartial) { return known }
        let file: PreviewFile
        if let buffer = unsaved[path] {
            file = buffer.utf8.count > previewByteLimit ? .tooLarge : .text(lines: PreviewFile.lines(of: buffer), isWhole: true)
        } else {
            file = PreviewFile.read(path, whole: whole, wholeLimit: previewByteLimit)
        }
        previewFiles[path] = file
        return file
    }
}

/// The overlay's drawing helpers, for its renderers too: text in the theme's
/// font, highlighted ranges, and drawing within a row.
@MainActor
struct OverlayStyle {
    let theme: Theme
    /// Space between parts of a line.
    let gap: CGFloat = 8

    /// `string` in the theme's font, one line, cut at `truncation`.
    func attributed(
        _ string: String, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        return NSAttributedString(string: string, attributes: [
            .font: theme.font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    /// `text` with `ranges` (clipped to it) in the accent color, bold.
    func highlighted(_ text: NSAttributedString, _ ranges: [NSRange]) -> NSAttributedString {
        let marked = NSMutableAttributedString(attributedString: text)
        let bold = NSFontManager.shared.convert(theme.font, toHaveTrait: .boldFontMask)
        let whole = NSRange(location: 0, length: marked.length)
        for range in ranges {
            let clipped = NSIntersectionRange(range, whole)
            guard clipped.length > 0 else { continue }
            marked.addAttributes([.foregroundColor: theme.folder, .font: bold], range: clipped)
        }
        return marked
    }

    /// The glyphs' box within a line, centered vertically.
    func glyphRect(in line: NSRect) -> NSRect {
        let glyphHeight = theme.font.ascender - theme.font.descender
        return NSRect(x: line.minX, y: line.minY + (line.height - glyphHeight) / 2, width: line.width, height: glyphHeight)
    }

    /// Draws text in `line` from `x`, at most `width` wide.
    func draw(_ text: NSAttributedString, x: CGFloat, line: NSRect, width: CGFloat) {
        // Taller than the glyphs: text that doesn't fit its rect isn't drawn.
        let height = ceil(theme.font.ascender - theme.font.descender + theme.font.leading) + 2
        text.draw(in: NSRect(x: x, y: glyphRect(in: line).minY, width: max(width, 0), height: height))
    }
}
