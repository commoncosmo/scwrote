/// One file in the quick open list.
public struct QuickOpenRow: Equatable, Sendable {
    /// Absolute, in the form nvim takes.
    public let path: String
    public let relativePath: String
    /// The matched characters as UTF-16 offsets into `relativePath`.
    public let ranges: [Range<Int>]

    public init(path: String, relativePath: String, ranges: [Range<Int>]) {
        self.path = path
        self.relativePath = relativePath
        self.ranges = ranges
    }
}

/// The result list behind quick open. Until the user moves the selection it
/// is the top row, so the best match stays selected as the list is rebuilt;
/// once they move, the selection holds its file by path.
public struct QuickOpenResults: Equatable, Sendable {
    /// Rows past this are dropped; type more to narrow.
    public static let rowLimit = 200

    public private(set) var rows: [QuickOpenRow] = []
    /// Every match, including those past the row limit.
    public private(set) var matchCount = 0
    /// Files considered, after the hidden filter.
    public private(set) var fileCount = 0
    /// True until the first ranking arrives.
    public private(set) var isListing = true
    public private(set) var hidesHidden = false
    public private(set) var isEmptyQuery = true

    /// Set once the user moves the selection; nil means "the top row".
    private var selectedPath: String?

    public init() {}

    fileprivate init(rows: [QuickOpenRow], matchCount: Int, fileCount: Int, hidesHidden: Bool, isEmptyQuery: Bool) {
        self.rows = rows
        self.matchCount = matchCount
        self.fileCount = fileCount
        self.isListing = false
        self.hidesHidden = hidesHidden
        self.isEmptyQuery = isEmptyQuery
    }

    public var selectedIndex: Int? {
        guard !rows.isEmpty else { return nil }
        guard let selectedPath else { return 0 }
        return rows.firstIndex { $0.path == selectedPath } ?? 0
    }

    public var selected: QuickOpenRow? {
        selectedIndex.map { rows[$0] }
    }

    /// Moves the selection by `offset` rows, stopping at either end.
    public mutating func move(by offset: Int) {
        guard let current = selectedIndex else { return }
        selectedPath = rows[min(max(current + offset, 0), rows.count - 1)].path
    }

    public mutating func selectFirst() {
        selectedPath = rows.first?.path
    }

    public mutating func selectLast() {
        selectedPath = rows.last?.path
    }

    /// Takes `new`'s rows and counts. The held selection stays if its file is
    /// still listed; otherwise the top row is selected.
    public mutating func replace(with new: QuickOpenResults) {
        let held = selectedPath.flatMap { path in new.rows.contains { $0.path == path } ? path : nil }
        self = new
        selectedPath = held
    }

    public var countLine: String {
        if isListing { return "Listing files…" }
        let base: String
        if fileCount == 0 {
            base = "No files"
        } else if isEmptyQuery {
            base = Self.files(fileCount)
        } else if matchCount == 0 {
            base = "No files"
        } else {
            base = "\(matchCount) of \(Self.files(fileCount))"
        }
        return hidesHidden ? base + " · hidden off" : base
    }

    private static func files(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files")"
    }
}

public enum QuickOpenRanking {
    /// Added to the score of a file that is open in a pane. About one more
    /// matched character at a word start in the file name: enough to settle
    /// close calls, not enough to lift a scattered match over a good one.
    static let openFileBonus = 20

    /// Ranks `files` (relative paths in path order) against `query`. With no
    /// name it lists open files, then `history`, then the rest in path order.
    public static func rank(
        _ query: QuickOpenQuery, root: String, files: [String], openFiles: [String], history: [String],
        showsHidden: Bool
    ) -> QuickOpenResults {
        let files = showsHidden ? files : files.filter { !FolderFileList.isHidden(relativePath: $0) }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        func row(_ relative: String, _ ranges: [Range<Int>] = []) -> QuickOpenRow {
            QuickOpenRow(path: prefix + relative, relativePath: relative, ranges: ranges)
        }
        let limit = QuickOpenResults.rowLimit

        if query.isEmpty {
            let listed = Set(files)
            var seen = Set<String>()
            var ordered: [String] = []
            for path in openFiles + history where listed.contains(path) && seen.insert(path).inserted {
                ordered.append(path)
            }
            for path in files where ordered.count < limit && !seen.contains(path) { ordered.append(path) }
            return QuickOpenResults(
                rows: ordered.prefix(limit).map { row($0) }, matchCount: files.count, fileCount: files.count,
                hidesHidden: !showsHidden, isEmptyQuery: true)
        }

        let pattern = FuzzyPattern(query.name)
        let open = Set(openFiles)
        var hits: [(score: Int, index: Int)] = []
        for (index, path) in files.enumerated() {
            guard let match = FuzzyMatcher.match(pattern, in: path) else { continue }
            hits.append((match.score + (open.contains(path) ? openFileBonus : 0), index))
        }
        // Higher score, then shorter path, then path order (the index).
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let (pa, pb) = (files[a.index].utf8.count, files[b.index].utf8.count)
            return pa != pb ? pa < pb : a.index < b.index
        }
        let rows = hits.prefix(limit).map { hit in
            row(files[hit.index], FuzzyMatcher.match(pattern, in: files[hit.index])?.ranges ?? [])
        }
        return QuickOpenResults(
            rows: rows, matchCount: hits.count, fileCount: files.count, hidesHidden: !showsHidden,
            isEmptyQuery: false)
    }
}
