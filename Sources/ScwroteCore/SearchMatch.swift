/// One line of a project search that matched, ready to show in the results list.
public struct SearchMatch: Equatable, Hashable, Sendable {
    /// What identifies a result row: the file and line. Selection survives a
    /// re-run of the search by key, and results sort by it.
    public struct Key: Comparable, Hashable, Sendable {
        public let path: String
        public let line: Int

        public static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.path == rhs.path ? lhs.line < rhs.line : lhs.path < rhs.path
        }
    }

    /// Absolute, in nvim's form, so it compares with open buffers.
    public let path: String
    /// 1-based.
    public let line: Int
    /// Byte offset of the first match in the full line, 0-based: the column
    /// nvim's cursor takes when it jumps here.
    public let column: Int
    /// What the list displays: leading whitespace trimmed, at most 200
    /// characters, with "…" where the line was cut.
    public let text: String
    /// Matches within `text`, as UTF-16 offsets so AppKit can draw them as
    /// `NSRange`s. Clipped to what `text` shows.
    public let ranges: [Range<Int>]

    public var key: Key { Key(path: path, line: line) }

    public init(path: String, line: Int, column: Int, text: String, ranges: [Range<Int>]) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
        self.ranges = ranges
    }
}
