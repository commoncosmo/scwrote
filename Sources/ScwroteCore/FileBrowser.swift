import Foundation

public struct FileEntry: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
}

/// A key press, already translated from the platform's key event.
public enum BrowserKey: Equatable, Sendable {
    case character(Character)
    case up, down, left, right
    case enter, escape
    case halfPageDown, halfPageUp
}

/// What the browser asks its host to do after a key.
public enum BrowserAction: Equatable, Sendable {
    case open(String)
    case leave
    /// `a`: ask for a name and create a file or folder.
    case add
    /// `r`: ask for a new name for the item at this path.
    case rename(String)
    /// `d`: ask before moving the item at this path to the Trash.
    case delete(String)
}

/// A netrw-style tree of one folder, driven by vim keys. Pure state: it lists
/// folders from disk but knows nothing about drawing or nvim.
public struct FileBrowser {
    public struct Row: Equatable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public let isExpanded: Bool
    }

    /// Never shown, even with dotfiles on.
    private static let alwaysHidden: Set<String> = [".git", ".DS_Store"]

    public private(set) var root: String
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var showsDotfiles = true

    /// Folders the user opened. Kept when a parent closes, so reopening the
    /// parent restores what was open inside it.
    private var expanded: Set<String> = []
    /// Folder listings, read from disk once until `reload()`.
    private var listings: [String: [FileEntry]] = [:]
    /// A count typed before a motion, as in `3j`.
    private var count: Int?
    /// `g` was typed and waits for its second key (`gg`, `gh`).
    private var pendingG = false

    public init(root: String) {
        self.root = root
        rebuildRows()
    }

    public var selectedEntry: FileEntry? {
        rows.indices.contains(cursor) ? rows[cursor].entry : nil
    }

    public var selectedPath: String? { selectedEntry?.path }

    public mutating func handle(_ key: BrowserKey, pageHeight: Int) -> BrowserAction? {
        if pendingG {
            pendingG = false
            defer { count = nil }
            switch key {
            case .character("g"): select(line: count ?? 1)
            case .character("h"): toggleDotfiles()
            default: break
            }
            return nil
        }

        if case let .character(character) = key, let digit = character.wholeNumberValue,
           digit > 0 || count != nil {
            count = min((count ?? 0) * 10 + digit, 99_999)
            return nil
        }

        let typedCount = count
        let times = typedCount ?? 1
        count = nil
        let halfPage = max(1, pageHeight / 2)

        switch key {
        case .character("j"), .down: move(by: times)
        case .character("k"), .up: move(by: -times)
        case .character("l"), .right: return stepIn()
        case .character("h"), .left: stepOut()
        case .character("o"), .enter: return activate()
        case .character("G"): select(line: typedCount ?? rows.count)
        case .character("g"):
            pendingG = true
            count = typedCount
        case .character("-"): goUp()
        case .halfPageDown: move(by: halfPage)
        case .halfPageUp: move(by: -halfPage)
        case .escape: return .leave
        // A count before these means nothing; it is dropped like any other.
        case .character("a"): return .add
        case .character("r"): return selectedPath.map(BrowserAction.rename)
        case .character("d"): return selectedPath.map(BrowserAction.delete)
        default: break
        }
        return nil
    }

    /// Opens the folders down to `path` and selects it. Paths outside the
    /// root are ignored. Compares real paths, since nvim reports /private/var/...
    /// for a root reached through the /var symlink (and the like). Only the
    /// folders above the item are resolved, so a symlink to a file selects
    /// its own row, not its target's.
    public mutating func reveal(_ path: String) {
        let realRoot = Self.realPath(root)
        let realTarget = Self.nvimPath(of: path)
        guard realTarget.hasPrefix(realRoot == "/" ? "/" : realRoot + "/"), realTarget != realRoot else { return }
        let target = root + realTarget.dropFirst(realRoot.count)
        var folder = (target as NSString).deletingLastPathComponent
        while folder.count > root.count {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        rebuildRows(keeping: target)
    }

    /// A path the way nvim names its buffer: the folders above it with every
    /// symlink resolved, since `:edit root/linkdir/x.md` names the buffer
    /// after the folder the link points to (and `/var/...` is
    /// `/private/var/...`). The item itself keeps its own name, so a symlink
    /// to a file, renamed or deleted, never stands for the file it points to.
    /// Works for an item that's gone, as long as its folder is there.
    public static func nvimPath(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return (realPath(folder) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// A row's path as nvim names the buffers under it: a folder fully
    /// resolved (a symlink to a folder stands for its target, where the files
    /// inside are named), a file as `nvimPath(of:)`.
    public static func nvimPath(of path: String, isDirectory: Bool) -> String {
        isDirectory ? realPath(path) : nvimPath(of: path)
    }

    /// The path with every symlink resolved (realpath(3)), or as given if it
    /// doesn't exist.
    public static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Selects a row directly, as a mouse click does.
    public mutating func select(row: Int) {
        guard rows.indices.contains(row) else { return }
        cursor = row
        count = nil
        pendingG = false
    }

    /// Reads folders from disk again (files changed), keeping the selection.
    public mutating func reload() {
        listings.removeAll()
        rebuildRows(keeping: selectedPath)
    }

    // MARK: - Keys

    private mutating func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(cursor + offset, 0), rows.count - 1)
    }

    /// Line numbers count from 1, as in vim.
    private mutating func select(line: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(line - 1, 0), rows.count - 1)
    }

    /// `l`: open a closed folder, step into an open one, open a file.
    private mutating func stepIn() -> BrowserAction? {
        guard let row = rows[safe: cursor] else { return nil }
        guard row.entry.isDirectory else { return .open(row.entry.path) }
        if !row.isExpanded {
            setExpanded(row.entry.path, true)
        } else if let next = rows[safe: cursor + 1], next.depth > row.depth {
            cursor += 1
        }
        return nil
    }

    /// `h`: close an open folder, otherwise jump to the folder containing this row.
    private mutating func stepOut() {
        guard let row = rows[safe: cursor] else { return }
        if row.isExpanded {
            setExpanded(row.entry.path, false)
        } else if row.depth > 0,
                  let parent = rows[..<cursor].lastIndex(where: { $0.depth == row.depth - 1 }) {
            cursor = parent
        }
    }

    /// Enter / `o`: open a file, or open/close a folder.
    private mutating func activate() -> BrowserAction? {
        guard let row = rows[safe: cursor] else { return nil }
        guard row.entry.isDirectory else { return .open(row.entry.path) }
        setExpanded(row.entry.path, !row.isExpanded)
        return nil
    }

    /// `-`: show the parent folder, with the folder you were in open and selected.
    private mutating func goUp() {
        let parent = (root as NSString).deletingLastPathComponent
        guard parent != root, !parent.isEmpty else { return }
        let previous = root
        root = parent
        expanded.insert(previous)
        rebuildRows(keeping: previous)
    }

    private mutating func toggleDotfiles() {
        showsDotfiles.toggle()
        rebuildRows(keeping: selectedPath)
    }

    private mutating func setExpanded(_ path: String, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(path) } else { expanded.remove(path) }
        rebuildRows(keeping: selectedPath)
    }

    // MARK: - Rows

    private mutating func rebuildRows(keeping selection: String? = nil) {
        loadListings(for: root)
        rows = Self.flatten(
            root, depth: 0, listings: listings, expanded: expanded, showsDotfiles: showsDotfiles
        )
        if let selection, let index = rows.firstIndex(where: { $0.entry.path == selection }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
        }
    }

    /// Reads `folder` and every open folder inside it into the cache.
    private mutating func loadListings(for folder: String) {
        if listings[folder] == nil {
            listings[folder] = Self.list(folder)
        }
        for entry in listings[folder] ?? [] where entry.isDirectory && expanded.contains(entry.path) {
            loadListings(for: entry.path)
        }
    }

    private static func flatten(
        _ folder: String,
        depth: Int,
        listings: [String: [FileEntry]],
        expanded: Set<String>,
        showsDotfiles: Bool
    ) -> [Row] {
        (listings[folder] ?? [])
            .filter { !alwaysHidden.contains($0.name) && (showsDotfiles || !$0.name.hasPrefix(".")) }
            .flatMap { entry -> [Row] in
                let isExpanded = entry.isDirectory && expanded.contains(entry.path)
                let row = Row(entry: entry, depth: depth, isExpanded: isExpanded)
                guard isExpanded else { return [row] }
                return [row] + flatten(
                    entry.path, depth: depth + 1, listings: listings,
                    expanded: expanded, showsDotfiles: showsDotfiles
                )
            }
    }

    /// Folders first, then files, each in Finder's order ("file2" before "file10").
    private static func list(_ folder: String) -> [FileEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names
            .map { name in
                let path = folder == "/" ? "/\(name)" : "\(folder)/\(name)"
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return FileEntry(name: name, path: path, isDirectory: isDirectory.boolValue)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
