import AppKit
import ScwroteCore

/// What one kind of overlay draws inside `ListOverlayView`'s panel: its rows,
/// what to preview for the selected one, and its key hints.
@MainActor
protocol OverlayRenderer {
    associatedtype List: OverlayList
    init()
    /// Rows and the count show for an empty query too.
    static var listsEmptyQuery: Bool { get }
    /// Cmd+Shift+. shows or hides hidden files.
    static var togglesHidden: Bool { get }
    /// The whole panel when ripgrep is missing.
    static var missingRipgrepMessage: String { get }
    func footer(_ mode: SearchOverlayMode) -> String
    /// Draws `item` within `row` (the row's text area, inside its selection).
    func drawRow(_ item: List.Item, in row: NSRect, root: String, style: OverlayStyle)
    func preview(of item: List.Item, query: String) -> OverlayPreview
}

/// The file to preview for the selected row.
struct OverlayPreview {
    let path: String
    /// 1-based: the line centered and tinted. Nil starts at the top and
    /// tints nothing.
    let line: Int?
    /// The ranges to mark in a preview line (UTF-16).
    let highlights: (String) -> [NSRange]
}

/// Project search's matches.
struct SearchMatchRenderer: OverlayRenderer {
    typealias List = SearchResults
    static let listsEmptyQuery = false
    static let togglesHidden = false
    static let missingRipgrepMessage = "Search needs ripgrep — run scripts/fetch-ripgrep.sh or brew install ripgrep"

    func footer(_ mode: SearchOverlayMode) -> String {
        mode == .typing
            ? "⌃J/⌃K move · Esc → list (j/k) · ↩ open · ⌃Q quickfix"
            : "j/k move · Esc close · ↩ open · i back to typing · ⌃Q quickfix"
    }

    /// The match's text with the match in the accent color, and `path:line`
    /// at the right. The path gives way first, cut from the start, down to
    /// 45% of the row.
    func drawRow(_ match: SearchMatch, in row: NSRect, root: String, style: OverlayStyle) {
        let rootPrefix = root == "/" ? "/" : root + "/"
        let path = match.path.hasPrefix(rootPrefix) ? String(match.path.dropFirst(rootPrefix.count)) : match.path
        let location = style.attributed("\(path):\(match.line)", color: style.dimText, truncation: .byTruncatingHead)
        let room = row.width - style.gap
        let locationWidth = min(ceil(location.size().width), room * 0.45)
        style.draw(location, x: row.maxX - locationWidth, line: row, width: locationWidth)
        let text = style.highlighted(style.attributed(match.text, color: style.text), match.ranges.map { NSRange($0) })
        style.draw(text, x: row.minX, line: row, width: room - locationWidth)
    }

    /// Centered on the match's line, every occurrence of the query marked.
    func preview(of match: SearchMatch, query: String) -> OverlayPreview {
        OverlayPreview(path: match.path, line: match.line) { Self.occurrences(of: query, in: $0) }
    }

    /// Where `query` appears in `line`, ignoring case, as UTF-16 ranges.
    private static func occurrences(of query: String, in line: String) -> [NSRange] {
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
}

/// Quick open's files.
struct QuickOpenRenderer: OverlayRenderer {
    typealias List = QuickOpenResults
    static let listsEmptyQuery = true
    static let togglesHidden = true
    static let missingRipgrepMessage = "Quick open needs ripgrep — run scripts/fetch-ripgrep.sh or brew install ripgrep"

    func footer(_ mode: SearchOverlayMode) -> String {
        mode == .typing
            ? "⌃J/⌃K move · Esc → list (j/k) · ↩ open · ⌘⇧. hidden"
            : "j/k move · Esc close · ↩ open · i back to typing · ⌘⇧. hidden"
    }

    /// The file's name, then its folder dimmed (nothing for a file at the
    /// root), the matched characters marked in both. The folder gives way
    /// first, cut from the start.
    func drawRow(_ file: QuickOpenRow, in row: NSRect, root _: String, style: OverlayStyle) {
        let relative = file.relativePath as NSString
        let slash = relative.range(of: "/", options: .backwards).location
        let nameStart = slash == NSNotFound ? 0 : slash + 1
        let ranges = file.ranges.map { NSRange($0) }

        let nameRanges = ranges.compactMap { range -> NSRange? in
            let lower = max(range.location, nameStart)
            return NSMaxRange(range) > lower ? NSRange(location: lower - nameStart, length: NSMaxRange(range) - lower) : nil
        }
        let name = style.highlighted(
            style.attributed(relative.substring(from: nameStart), color: style.text), nameRanges)
        let nameWidth = min(ceil(name.size().width), row.width)
        style.draw(name, x: row.minX, line: row, width: nameWidth)

        guard slash != NSNotFound else { return }
        let folderX = row.minX + nameWidth + style.gap
        guard row.maxX > folderX else { return }
        let folder = style.highlighted(
            style.attributed(relative.substring(to: slash), color: style.dimText, truncation: .byTruncatingHead), ranges)
        style.draw(folder, x: folderX, line: row, width: row.maxX - folderX)
    }

    /// At the query's `:line` if it has one, else from the top; nothing marked.
    func preview(of file: QuickOpenRow, query: String) -> OverlayPreview {
        OverlayPreview(path: file.path, line: QuickOpenQuery(query).line) { _ in [] }
    }
}

typealias SearchOverlayView = ListOverlayView<SearchMatchRenderer>
typealias QuickOpenView = ListOverlayView<QuickOpenRenderer>
