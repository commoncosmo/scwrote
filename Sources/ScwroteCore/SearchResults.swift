/// The result list behind the search overlay. Matches stream in from ripgrep
/// in whatever order its workers finish, and this keeps them sorted by file
/// then line, capped, and the selection steady.
///
/// Until the user moves the selection it is the top row, so the best-sorted
/// match stays selected while results arrive. Once they move, the selection
/// holds its match by key and new rows slide in around it.
public struct SearchResults: Equatable, Sendable {
    /// Past this many rows the rest are dropped; narrow the query instead.
    public static let cap = 1000

    /// Sorted by key, one per file and line.
    public private(set) var matches: [SearchMatch] = []
    public private(set) var isCapped = false
    public private(set) var isFinished = false

    private var paths: Set<String> = []
    /// Set once the user moves the selection; nil means "the top row".
    private var selectedKey: SearchMatch.Key?

    public init() {}

    public var fileCount: Int { paths.count }

    public var selectedIndex: Int? {
        guard !matches.isEmpty else { return nil }
        guard let selectedKey else { return 0 }
        let index = insertionIndex(for: selectedKey)
        return index < matches.count && matches[index].key == selectedKey ? index : 0
    }

    public var selected: SearchMatch? {
        selectedIndex.map { matches[$0] }
    }

    /// Adds a batch, skipping rows already shown (same file and line) and
    /// anything past the cap. Rows arriving after the cap are dropped even if
    /// they would sort earlier.
    public mutating func add(_ batch: [SearchMatch]) {
        for match in batch {
            let index = insertionIndex(for: match.key)
            if index < matches.count, matches[index].key == match.key { continue }
            guard matches.count < Self.cap else {
                isCapped = true
                return
            }
            matches.insert(match, at: index)
            paths.insert(match.path)
        }
    }

    public mutating func finish() {
        isFinished = true
    }

    /// Moves the selection by `offset` rows, stopping at either end.
    public mutating func move(by offset: Int) {
        guard let current = selectedIndex else { return }
        let target = min(max(current + offset, 0), matches.count - 1)
        selectedKey = matches[target].key
    }

    public mutating func selectFirst() {
        selectedKey = matches.first?.key
    }

    public mutating func selectLast() {
        selectedKey = matches.last?.key
    }

    public var countLine: String {
        if isCapped { return "\(Self.cap)+ matches" }
        if matches.isEmpty { return isFinished ? "No matches" : "Searching…" }
        return "\(Self.counted(matches.count, "match", "matches")) · \(Self.counted(fileCount, "file", "files"))"
    }

    private static func counted(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// Where `key` is, or would go, in `matches`.
    private func insertionIndex(for key: SearchMatch.Key) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].key < key { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
