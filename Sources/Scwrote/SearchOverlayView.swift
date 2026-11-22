import AppKit
import ScwroteCore

/// Cmd+Shift+F's search overlay, drawn like the file browser (the theme's
/// font and colors): the query with the count beside it, the matches, a
/// preview of the selected one and the key hints. It covers the whole window,
/// clear outside its panel, so a click anywhere outside the panel closes it.
@MainActor
final class SearchOverlayView: NSView {
    private(set) var overlay = TextSearchOverlay()
    let theme: Theme
    /// The searched folder, resolved like the matches' paths, which show
    /// relative to it.
    var root = "" { didSet { needsDisplay = true } }
    /// No ripgrep was found: the panel says how to get one, and nothing else.
    var isMissingRipgrep = false { didSet { needsDisplay = true } }
    /// Unsaved buffers' text by path. The preview shows these rather than
    /// what's on disk.
    var unsaved: [String: String] = [:] {
        didSet {
            previewLines.removeAll()
            needsDisplay = true
        }
    }

    var results: SearchResults {
        get { overlay.results }
        set {
            overlay.results = newValue
            scrollToSelection()
        }
    }

    /// The query changed, a match was chosen, or the overlay asked to close.
    var onAction: ((SearchAction<SearchMatch>) -> Void)?

    /// Files' lines for the preview, read once per opening (see `reopen()`);
    /// nil for a file too large to preview.
    private var previewLines: [String: [Substring]?] = [:]
    /// First result row drawn; scrolls to keep the selection in view.
    private var topRow = 0
    /// Scrolling not yet worth a whole row, in rows.
    private var scrollRemainder: CGFloat = 0

    private let padding: CGFloat = 10
    private let gap: CGFloat = 8
    private let tab = "    "
    /// Long lines are cut here before drawing; the preview clips them anyway.
    private let previewColumns = 400
    /// Larger files aren't previewed: they're read on the main thread while
    /// drawing, and a huge log would stall typing.
    private let previewByteLimit = 8 * 1024 * 1024

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
        previewLines.removeAll()
        needsDisplay = true
    }

    /// A key, as the keyboard would send it (also for the debug hooks).
    /// Without ripgrep only Esc means anything: it closes.
    func press(_ key: SearchKey) {
        if isMissingRipgrep {
            if key == .escape { onAction?(.close) }
            return
        }
        send(overlay.handle(key, pageHeight: frames.rows))
    }

    private func send(_ action: SearchAction<SearchMatch>?) {
        scrollToSelection()
        if let action { onAction?(action) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let key = Self.searchKey(for: event) else { return }
        // A held Esc or Enter acts once: a repeat would close the list it
        // just switched to, or open the match again.
        if event.isARepeat, key == .escape || key == .enter { return }
        press(key)
    }

    /// There's no Edit menu (Cmd+V is the terminal's), so paste is handled
    /// here: into the query while typing, nowhere in the list.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if window?.firstResponder === self, event.type == .keyDown, flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if !isMissingRipgrep, overlay.mode == .typing {
                send(overlay.paste(NSPasteboard.general.string(forType: .string) ?? ""))
            }
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

    /// A click selects a match, a double-click opens it, and a click outside
    /// the panel closes the overlay.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let frames = frames
        guard frames.panel.contains(point) else {
            onAction?(.close)
            return
        }
        guard !isMissingRipgrep, frames.list.contains(point), let current = results.selectedIndex else { return }
        let row = topRow + Int((point.y - frames.list.minY) / lineHeight)
        guard row < results.matches.count else { return }
        overlay.results.move(by: row - current)
        needsDisplay = true
        if event.clickCount == 2 { press(.enter) }
    }

    /// Scrolling moves the selection a row at a time, so the list follows
    /// it as it does the keys.
    override func scrollWheel(with event: NSEvent) {
        guard !isMissingRipgrep, !results.matches.isEmpty else { return }
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
        topRow = min(max(topRow, 0), max(results.matches.count - rows, 0))
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        let frames = frames
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
            let message = attributed(
                "Search needs ripgrep — run scripts/fetch-ripgrep.sh or brew install ripgrep", color: theme.warning)
            draw(message, x: frames.query.minX, line: frames.query, width: frames.query.width)
            return
        }
        drawQuery(in: frames.query)
        drawRows(in: frames.list, rows: frames.rows)
        theme.divider.setFill()
        NSRect(x: frames.panel.minX, y: frames.list.maxY + gap, width: frames.panel.width, height: 1).fill()
        drawPreview(in: frames.preview)
        theme.divider.setFill()
        NSRect(x: frames.panel.minX, y: frames.footer.minY - gap / 2, width: frames.panel.width, height: 1).fill()
        let footer = overlay.mode == .typing
            ? "⌃J/⌃K move · Esc → list (j/k) · ↩ open"
            : "j/k move · Esc close · ↩ open · i back to typing"
        draw(attributed(footer, color: theme.dim), x: frames.footer.minX, line: frames.footer, width: frames.footer.width)
    }

    /// The query in a field, the count at its right. While typing, a bar
    /// marks the cursor; a reopened query is drawn selected. Text too long
    /// for the field slides left so the cursor stays in view.
    private func drawQuery(in box: NSRect) {
        let field = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        theme.selectionInactive.setFill()
        field.fill()
        theme.divider.setStroke()
        field.stroke()

        let inner = box.insetBy(dx: 8, dy: 0)
        var available = inner.width
        let query = overlay.query
        if !query.text.isEmpty {
            let count = attributed(results.countLine, color: theme.dim)
            let width = ceil(count.size().width)
            draw(count, x: inner.maxX - width, line: box, width: width)
            available -= width + gap * 2
        }

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: inner.minX, y: box.minY, width: max(available, 0), height: box.height).clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let beforeCursor = String(Array(query.text)[..<query.cursor])
        let cursorX = ceil(attributed(beforeCursor, color: theme.foreground).size().width)
        let x = inner.minX - max(0, cursorX + 2 - available)
        let text = attributed(query.text, color: theme.foreground, truncation: .byClipping)
        let textWidth = ceil(text.size().width)
        let glyphs = glyphRect(in: box)
        if overlay.isQuerySelected, !query.text.isEmpty {
            theme.selection.setFill()
            NSRect(x: x, y: glyphs.minY, width: textWidth, height: glyphs.height).fill()
        }
        draw(text, x: x, line: box, width: textWidth + 2)
        if overlay.mode == .typing, !overlay.isQuerySelected {
            theme.folder.setFill()
            NSRect(x: x + cursorX, y: glyphs.minY, width: 2, height: glyphs.height).fill()
        }
    }

    /// One row per match: its text with the match in the accent color, and
    /// `path:line` at the right. The path gives way first, cut from the
    /// start, down to 45% of the row.
    private func drawRows(in list: NSRect, rows: Int) {
        guard !overlay.query.text.isEmpty else { return }
        let matches = results.matches
        let selected = results.selectedIndex
        let rootPrefix = root == "/" ? "/" : root + "/"
        for index in topRow ..< min(matches.count, topRow + rows) {
            let match = matches[index]
            let row = NSRect(x: list.minX, y: list.minY + CGFloat(index - topRow) * lineHeight, width: list.width, height: lineHeight)
            if index == selected {
                theme.selection.setFill()
                NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
            }
            let inner = row.insetBy(dx: 6, dy: 0)
            let path = match.path.hasPrefix(rootPrefix) ? String(match.path.dropFirst(rootPrefix.count)) : match.path
            let location = attributed("\(path):\(match.line)", color: theme.dim, truncation: .byTruncatingHead)
            let room = inner.width - gap
            let locationWidth = min(ceil(location.size().width), room * 0.45)
            draw(location, x: inner.maxX - locationWidth, line: row, width: locationWidth)
            let text = highlighted(attributed(match.text, color: theme.foreground), match.ranges.map { NSRange($0) })
            draw(text, x: inner.minX, line: row, width: room - locationWidth)
        }
    }

    /// The selected match's file: its name, then numbered lines centered on
    /// the match, the match's line tinted and every occurrence of the query
    /// in the accent color. Tabs are 4 spaces; long lines are clipped.
    private func drawPreview(in area: NSRect) {
        guard let match = results.selected, area.height >= lineHeight else { return }
        let header = NSRect(x: area.minX, y: area.minY, width: area.width, height: lineHeight)
        draw(attributed((match.path as NSString).lastPathComponent, color: theme.dim), x: area.minX, line: header, width: area.width)

        let visible = Int((area.height - lineHeight) / lineHeight)
        guard visible > 0 else { return }
        guard let lines = previewLines(for: match.path) else {
            let line = NSRect(x: area.minX, y: header.maxY, width: area.width, height: lineHeight)
            draw(attributed("File too large to preview", color: theme.dim), x: area.minX + 6, line: line, width: area.width - 6)
            return
        }
        guard !lines.isEmpty else { return }
        let first = max(1, min(match.line - visible / 2, lines.count - visible + 1))
        let last = min(lines.count, first + visible - 1)
        let numberWidth = ceil(attributed(String(last), color: theme.dim).size().width)
        let textX = area.minX + 6 + numberWidth + gap

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        area.clip()
        for number in first ... last {
            let line = NSRect(x: area.minX, y: header.maxY + CGFloat(number - first) * lineHeight, width: area.width, height: lineHeight)
            if number == match.line {
                theme.selectionInactive.setFill()
                NSBezierPath(roundedRect: line, xRadius: 4, yRadius: 4).fill()
            }
            let label = attributed(String(number), color: theme.dim)
            let labelWidth = ceil(label.size().width)
            draw(label, x: textX - gap - labelWidth, line: line, width: labelWidth)
            let content = lines[number - 1].prefix(previewColumns).replacingOccurrences(of: "\t", with: tab)
            let text = highlighted(attributed(content, color: theme.foreground, truncation: .byClipping), occurrences(of: overlay.query.text, in: content))
            draw(text, x: textX, line: line, width: area.maxX - textX)
        }
    }

    /// The unsaved buffer's lines if there is one, else the file's, read
    /// once; nil past `previewByteLimit`.
    private func previewLines(for path: String) -> [Substring]? {
        if let known = previewLines[path] { return known }
        let lines = previewText(of: path).map { text -> [Substring] in
            guard !text.isEmpty else { return [] }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            if text.hasSuffix("\n") { lines.removeLast() }
            return lines
        }
        previewLines[path] = .some(lines)
        return lines
    }

    /// The unsaved buffer's text if there is one, else the file's ("" if it
    /// can't be read), reading at most one byte past `previewByteLimit`;
    /// nil past it.
    private func previewText(of path: String) -> String? {
        if let buffer = unsaved[path] { return buffer.utf8.count > previewByteLimit ? nil : buffer }
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: previewByteLimit + 1) else { return "" }
        return data.count > previewByteLimit ? nil : String(decoding: data, as: UTF8.self)
    }

    /// Where `query` appears in `line`, ignoring case, as UTF-16 ranges.
    private func occurrences(of query: String, in line: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let line = line as NSString
        var found: [NSRange] = []
        var start = 0
        while true {
            let range = line.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: line.length - start))
            guard range.location != NSNotFound else { return found }
            found.append(range)
            start = range.upperBound
        }
    }

    /// `text` with `ranges` (clipped to it) in the accent color, bold.
    private func highlighted(_ text: NSAttributedString, _ ranges: [NSRange]) -> NSAttributedString {
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

    /// `string` in the theme's font, one line, cut at `truncation`.
    private func attributed(
        _ string: String, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        return NSAttributedString(string: string, attributes: [
            .font: theme.font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    /// The glyphs' box within a line, centered vertically.
    private func glyphRect(in line: NSRect) -> NSRect {
        let glyphHeight = theme.font.ascender - theme.font.descender
        return NSRect(x: line.minX, y: line.minY + (line.height - glyphHeight) / 2, width: line.width, height: glyphHeight)
    }

    /// Draws text in `line` from `x`, at most `width` wide.
    private func draw(_ text: NSAttributedString, x: CGFloat, line: NSRect, width: CGFloat) {
        // Taller than the glyphs: text that doesn't fit its rect isn't drawn.
        let height = ceil(theme.font.ascender - theme.font.descender + theme.font.leading) + 2
        text.draw(in: NSRect(x: x, y: glyphRect(in: line).minY, width: max(width, 0), height: height))
    }
}
