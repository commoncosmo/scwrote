import AppKit
import ScwroteCore

/// Draws a `FileBrowser` like a terminal pane (one monospaced line per row, in
/// the Ghostty theme's colors) and feeds it vim keys.
@MainActor
final class FileBrowserView: NSView {
    private(set) var browser: FileBrowser
    var theme: Theme { didSet { needsDisplay = true } }
    var isPinned = false { didSet { needsDisplay = true } }
    /// The terminal's line height, once Ghostty has measured it: rows match
    /// it so the browser reads like part of the same terminal.
    var cellHeight: CGFloat? {
        didSet { if cellHeight != oldValue { scrollToCursor() } }
    }

    /// The browser asked to open a file or to leave.
    var onAction: ((BrowserAction) -> Void)?
    /// The user clicked into the browser.
    var onClick: (() -> Void)?
    /// `-` moved the browser to another folder.
    var onRootChange: ((String) -> Void)?
    /// The one-line prompt for add, rename and delete, on the bottom row.
    /// While it's open, keys go to it instead of the browser.
    var prompt: BrowserPrompt? {
        didSet {
            needsDisplay = true
            // It takes a row, which may have been the cursor's.
            if (prompt == nil) != (oldValue == nil) { scrollToCursor() }
        }
    }
    /// The prompt was confirmed, submitted or cancelled. The host closes it
    /// or, for a failed action, shows the error on it.
    var onPrompt: ((BrowserPrompt.Outcome) -> Void)?
    /// Files with unsaved changes in nvim. Their rows, and the folders above
    /// them, get a dot; the header counts them.
    var unsaved = UnsavedFiles() { didSet { needsDisplay = true } }
    /// Rows' paths in nvim's form (`FileBrowser.nvimPath(of:)`), resolved
    /// once until the next reload rather than at every draw.
    private var nvimPaths: [String: String] = [:]
    /// Held keys repeat in the prompt, but not the one that opened or closed
    /// it, nor any in a delete question (see `PromptKeyRepeats`).
    private var repeats = PromptKeyRepeats()

    /// First row drawn; scrolls to keep the cursor in view.
    private var topRow = 0
    private var scrollRemainder: CGFloat = 0
    private let sidePadding: CGFloat = 8

    init(browser: FileBrowser, theme: Theme) {
        self.browser = browser
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    /// Leaving the browser (a click elsewhere, another pane) cancels the
    /// prompt: its keys would otherwise go somewhere it isn't.
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        if prompt != nil { onPrompt?(.cancelled) }
        return true
    }

    // MARK: - Driving the browser

    func reveal(_ path: String) {
        browser.reveal(path)
        scrollToCursor(centered: true)
    }

    func reload() {
        nvimPaths.removeAll()
        browser.reload()
        scrollToCursor()
    }

    /// What the key asked the host to do, if anything.
    @discardableResult
    func press(_ key: BrowserKey) -> BrowserAction? {
        if prompt != nil {
            if let promptKey = PromptKey(key) { press(promptKey) } else { pressUnmapped() }
            return nil
        }
        let previousRoot = browser.root
        let action = browser.handle(key, pageHeight: visibleRowCount)
        if browser.root != previousRoot { onRootChange?(browser.root) }
        scrollToCursor()
        if let action { onAction?(action) }
        return action
    }

    func press(_ key: PromptKey) {
        guard var prompt else { return }
        let outcome = prompt.handle(key)
        self.prompt = prompt
        if outcome != .editing { onPrompt?(outcome) }
    }

    /// A key the prompt has no use for (↑, Ctrl-d, a Cmd key): the prompt
    /// decides what that means (see `BrowserPrompt.handleUnmapped()`).
    private func pressUnmapped() {
        guard var prompt else { return }
        let outcome = prompt.handleUnmapped()
        self.prompt = prompt
        if outcome != .editing { onPrompt?(outcome) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let inDeleteQuestion = if case .delete = prompt?.kind { true } else { false }
        if repeats.drops(keyCode: event.keyCode, isRepeat: event.isARepeat, inDeleteQuestion: inDeleteQuestion) {
            return
        }
        let wasOpen = prompt != nil
        var askedForPrompt = false
        // Cmd keys reached the prompt through performKeyEquivalent already.
        if prompt != nil, !event.modifierFlags.contains(.command) {
            if let key = Self.promptKey(for: event) { press(key) } else { pressUnmapped() }
        } else if let key = Self.browserKey(for: event) {
            switch press(key) {
            case .add, .rename, .delete: askedForPrompt = true
            case .open, .leave, nil: break
            }
        } else {
            super.keyDown(with: event)
        }
        if askedForPrompt || (prompt != nil) != wasOpen { repeats.openedOrClosedPrompt(keyCode: event.keyCode) }
    }

    override func keyUp(with event: NSEvent) {
        repeats.released(keyCode: event.keyCode)
        super.keyUp(with: event)
    }

    /// A Cmd key while the prompt has the keyboard counts as a key it has no
    /// use for (a delete is cancelled), then does what it always does. The
    /// window's own shortcuts never get here: the window takes them first,
    /// and they close the prompt themselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if prompt != nil, window?.firstResponder === self, event.type == .keyDown,
           event.modifierFlags.contains(.command), !event.isARepeat {
            pressUnmapped()
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Cmd combinations are left to the menu and window. The preview pane
    /// reads its keys the same way.
    static func browserKey(for event: NSEvent) -> BrowserKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return nil }
        switch event.keyCode {
        case 125: return .down
        case 126: return .up
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 53: return .escape
        default: break
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            default: return nil
            }
        }
        guard let characters = event.characters, characters.count == 1, let character = characters.first else {
            return nil
        }
        return .character(character)
    }

    /// The prompt's editing keys, as in vim's command line.
    static func promptKey(for event: NSEvent) -> PromptKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return nil }
        switch event.keyCode {
        case 51: return .backspace
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 53: return .escape
        default: break
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "a": return .start
            case "e": return .end
            case "w": return .deleteWord
            case "u": return .deleteToStart
            default: return nil
            }
        }
        return event.characters.flatMap(PromptKey.init(typed:))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onClick?()
        window?.makeFirstResponder(self)
        // The prompt acts on the item it opened for; a click doesn't change
        // which row looks selected under it.
        guard prompt == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Grid row 0 is the header.
        guard let gridRow = grid.row(atY: point.y), gridRow > 0 else { return }
        let row = topRow + gridRow - 1
        guard browser.rows.indices.contains(row) else { return }
        browser.select(row: row)
        needsDisplay = true
        if event.clickCount == 2 { press(BrowserKey.enter) }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? rowHeight : 1)
        let rows = Int(scrollRemainder)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows)
        topRow = clampedTop(topRow - rows)
        needsDisplay = true
    }

    // MARK: - Layout

    /// The terminal's line height, or the font's own until Ghostty reports it.
    private var rowHeight: CGFloat {
        cellHeight ?? ceil(theme.font.ascender - theme.font.descender + theme.font.leading)
    }

    /// The terminal's line grid: the header on row 0, entries from row 1, so
    /// each sits level with an nvim line.
    private var grid: RowGrid {
        RowGrid(top: Double(theme.topPadding), rowHeight: Double(rowHeight))
    }

    /// Entry rows that fit between the header and the bottom, less the
    /// prompt's row while it's open.
    private var visibleRowCount: Int {
        max(1, grid.rowsThatFit(height: Double(bounds.height)) - (prompt == nil ? 1 : 2))
    }

    /// The last whole grid row, where the prompt goes.
    private var bottomRow: Int {
        max(1, grid.rowsThatFit(height: Double(bounds.height)) - 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scrollToCursor()
    }

    private func scrollToCursor(centered: Bool = false) {
        let cursor = browser.cursor
        if centered, cursor < topRow || cursor >= topRow + visibleRowCount {
            topRow = cursor - visibleRowCount / 2
        } else if cursor < topRow {
            topRow = cursor
        } else if cursor >= topRow + visibleRowCount {
            topRow = cursor - visibleRowCount + 1
        }
        topRow = clampedTop(topRow)
        needsDisplay = true
    }

    private func clampedTop(_ top: Int) -> Int {
        min(max(top, 0), max(browser.rows.count - visibleRowCount, 0))
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        theme.background.setFill()
        bounds.fill()

        // The unsaved count sits at the right; the path gets what's left, cut
        // at the start: the folder's own name is the part that matters.
        var headerWidth = bounds.width - sidePadding * 2
        if unsaved.count > 0 {
            let count = attributed("● \(unsaved.count) unsaved", color: theme.warning)
            let width = ceil(count.size().width)
            draw(count, row: 0, x: bounds.width - sidePadding - width, width: width)
            headerWidth -= width + rowHeight
        }
        let header = (browser.root as NSString).abbreviatingWithTildeInPath + (isPinned ? "  · pinned" : "")
        draw(attributed(header, color: theme.dim, truncation: .byTruncatingHead), row: 0, x: sidePadding, width: headerWidth)

        if browser.rows.isEmpty {
            draw(attributed("(empty) · a: new file", color: theme.dim), row: 1, x: sidePadding, width: bounds.width - sidePadding * 2)
        } else {
            drawRows()
        }
        if let prompt { draw(prompt) }
    }

    private func drawRows() {
        let isFocused = window?.firstResponder === self
        let last = min(browser.rows.count, topRow + visibleRowCount + 1)
        for index in topRow ..< last {
            let row = browser.rows[index]
            let gridRow = index - topRow + 1
            if index == browser.cursor {
                (isFocused ? theme.selection : theme.selectionInactive).setFill()
                NSRect(x: 0, y: grid.rowTop(gridRow), width: bounds.width, height: rowHeight).fill()
            }
            let indent = String(repeating: "  ", count: row.depth)
            let marker = row.entry.isDirectory ? (row.isExpanded ? "▾ " : "▸ ") : "  "
            let name = row.entry.name + (row.entry.isDirectory ? "/" : "")
            let text = attributed(indent + marker + name, color: row.entry.isDirectory ? theme.folder : theme.foreground)
            if unsaved.count > 0, unsaved.marks(nvimPath(of: row.entry.path), isDirectory: row.entry.isDirectory) {
                drawMarked(text, row: gridRow)
            } else {
                draw(text, row: gridRow, x: sidePadding, width: bounds.width - sidePadding * 2)
            }
        }
    }

    /// The prompt on the bottom row, like vim's command line: the label dim,
    /// then the text with a block cursor. An error takes the row after a
    /// short label. A delete question is fitted to the row, keeping which
    /// item and `(y/N)` (see `DeleteQuestion.fitted`). Text too long for the
    /// row slides left so the cursor stays in view.
    private func draw(_ prompt: BrowserPrompt) {
        let row = bottomRow
        let rowRect = NSRect(x: 0, y: grid.rowTop(row), width: bounds.width, height: rowHeight)
        theme.background.setFill()
        rowRect.fill()
        let available = bounds.width - sidePadding * 2

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: sidePadding, y: rowRect.minY, width: available, height: rowRect.height).clip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let error = prompt.error {
            let label = attributed(prompt.errorLabel, color: theme.dim)
            let labelWidth = ceil(label.size().width)
            draw(label, row: row, x: sidePadding, width: labelWidth)
            let message = attributed(error, color: theme.warning)
            draw(message, row: row, x: sidePadding + labelWidth, width: available - labelWidth)
            return
        }

        let blank = attributed(" ", color: theme.foreground)
        if case let .delete(_, question) = prompt.kind {
            let cursorWidth = ceil(blank.size().width)
            let fitted = question.fitted(to: Double(available - cursorWidth)) { text in
                Double(ceil(self.attributed(text, color: self.theme.dim).size().width))
            }
            let label = attributed(fitted, color: theme.dim)
            let labelWidth = ceil(label.size().width)
            theme.selection.setFill()
            NSRect(x: sidePadding + labelWidth, y: rowRect.minY, width: cursorWidth, height: rowRect.height).fill()
            draw(label, row: row, x: sidePadding, width: labelWidth)
            return
        }

        let label = attributed(prompt.label, color: theme.dim, truncation: .byClipping)
        let labelWidth = ceil(label.size().width)
        let characters = Array(prompt.line.text)
        let cursor = prompt.line.cursor
        let beforeCursor = attributed(String(characters[..<cursor]), color: theme.foreground)
        let underCursor = cursor < characters.count ? attributed(String(characters[cursor]), color: theme.foreground) : blank
        let cursorX = labelWidth + ceil(beforeCursor.size().width)
        let cursorWidth = ceil(underCursor.size().width)
        let shift = max(0, cursorX + cursorWidth - available)
        let x = sidePadding - shift

        theme.selection.setFill()
        NSRect(x: x + cursorX, y: rowRect.minY, width: cursorWidth, height: rowRect.height).fill()
        draw(label, row: row, x: x, width: labelWidth)
        let text = attributed(prompt.line.text, color: theme.foreground, truncation: .byClipping)
        draw(text, row: row, x: x + labelWidth, width: ceil(text.size().width) + cursorWidth)
    }

    /// A row's path in nvim's form, to compare with `unsaved`.
    private func nvimPath(of path: String) -> String {
        if let known = nvimPaths[path] { return known }
        let resolved = FileBrowser.nvimPath(of: path)
        nvimPaths[path] = resolved
        return resolved
    }

    /// A row followed by the unsaved dot. A long name is cut, never the dot.
    private func drawMarked(_ text: NSAttributedString, row: Int) {
        let dot = attributed(" ●", color: theme.warning)
        let dotWidth = ceil(dot.size().width)
        let available = bounds.width - sidePadding * 2
        let textWidth = min(ceil(text.size().width), available - dotWidth)
        draw(text, row: row, x: sidePadding, width: textWidth)
        draw(dot, row: row, x: sidePadding + textWidth, width: dotWidth)
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

    /// Draws text on a grid row from `x`, at most `width` wide, its glyphs
    /// centered in the row the way Ghostty centers them in a cell.
    private func draw(_ text: NSAttributedString, row: Int, x: CGFloat, width: CGFloat) {
        let font = theme.font
        let glyphHeight = font.ascender - font.descender
        let y = grid.rowTop(row) + (rowHeight - glyphHeight) / 2
        // Taller than the glyphs: text that doesn't fit its rect isn't drawn.
        let height = ceil(glyphHeight + font.leading) + 2
        text.draw(in: NSRect(x: x, y: y, width: max(width, 0), height: height))
    }
}
