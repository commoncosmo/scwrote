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
    /// Files with unsaved changes in nvim. Their rows, and the folders above
    /// them, get a dot; the header counts them.
    var unsaved = UnsavedFiles() { didSet { needsDisplay = true } }
    /// The root with symlinks resolved, the form nvim reports paths in; kept
    /// for the root it was resolved from.
    private var realRoot: (root: String, real: String)?

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

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: - Driving the browser

    func reveal(_ path: String) {
        browser.reveal(path)
        scrollToCursor(centered: true)
    }

    func reload() {
        browser.reload()
        scrollToCursor()
    }

    func press(_ key: BrowserKey) {
        let previousRoot = browser.root
        let action = browser.handle(key, pageHeight: visibleRowCount)
        if browser.root != previousRoot { onRootChange?(browser.root) }
        scrollToCursor()
        if let action { onAction?(action) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if let key = Self.browserKey(for: event) {
            press(key)
        } else {
            super.keyDown(with: event)
        }
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onClick?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // Grid row 0 is the header.
        guard let gridRow = grid.row(atY: point.y), gridRow > 0 else { return }
        let row = topRow + gridRow - 1
        guard browser.rows.indices.contains(row) else { return }
        browser.select(row: row)
        needsDisplay = true
        if event.clickCount == 2 { press(.enter) }
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

    private var visibleRowCount: Int {
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
            return
        }

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

    /// A row's path in nvim's form, to compare with `unsaved`.
    private func nvimPath(of path: String) -> String {
        if realRoot?.root != browser.root {
            realRoot = (browser.root, FileBrowser.realPath(browser.root))
        }
        return browser.nvimPath(of: path, realRoot: realRoot!.real)
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
