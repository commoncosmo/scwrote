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

    /// Cmd combinations are left to the menu and window.
    private static func browserKey(for event: NSEvent) -> BrowserKey? {
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

        // Cut long paths at the start: the folder's own name is the part that matters.
        let header = (browser.root as NSString).abbreviatingWithTildeInPath + (isPinned ? "  · pinned" : "")
        drawLine(header, row: 0, color: theme.dim, truncation: .byTruncatingHead)

        if browser.rows.isEmpty {
            drawLine("(empty)", row: 1, color: theme.dim)
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
            drawLine(indent + marker + name, row: gridRow, color: row.entry.isDirectory ? theme.folder : theme.foreground)
        }
    }

    /// Draws one line of text on a grid row, its glyphs centered in the row
    /// the way Ghostty centers them in a cell.
    private func drawLine(
        _ text: String, row: Int, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        let attributed = NSAttributedString(string: text, attributes: [
            .font: theme.font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let font = theme.font
        let glyphHeight = font.ascender - font.descender
        let y = grid.rowTop(row) + (rowHeight - glyphHeight) / 2
        // Taller than the glyphs: text that doesn't fit its rect isn't drawn.
        let height = ceil(glyphHeight + font.leading) + 2
        attributed.draw(in: NSRect(x: sidePadding, y: y, width: bounds.width - sidePadding * 2, height: height))
    }
}
