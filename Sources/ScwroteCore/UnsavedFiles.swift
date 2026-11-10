/// The files open in nvim with changes not yet written, kept up to date from
/// nvim's events, and which file browser rows get the unsaved dot.
///
/// Paths are nvim's: absolute and with symlinks resolved. Callers compare
/// browser rows in that same form (see `FileBrowser.realPath(of:realRoot:)`).
public struct UnsavedFiles: Equatable, Sendable {
    public private(set) var paths: Set<String> = []

    public init() {}

    public var count: Int { paths.count }

    /// Takes in what an event says about a file's modified flag. Returns
    /// whether anything changed, so the browser only redraws when it must.
    @discardableResult
    public mutating func apply(_ event: PreviewEvent) -> Bool {
        switch event {
        case let .buffer(snapshot): set(snapshot.path, isModified: snapshot.isModified)
        case let .modified(path, isModified): set(path, isModified: isModified)
        case .cursor: false
        }
    }

    private mutating func set(_ path: String, isModified: Bool) -> Bool {
        isModified ? paths.insert(path).inserted : paths.remove(path) != nil
    }

    /// Whether a browser row gets the unsaved dot. `path` is the row's path in
    /// nvim's form; `isDirectory` says whether the row is a folder.
    ///
    /// A file gets the dot when it's unsaved. A folder gets it when it holds
    /// an unsaved file at any depth, open or collapsed, so the dots lead down
    /// to the file.
    public func marks(_ path: String, isDirectory: Bool) -> Bool {
        guard isDirectory else { return paths.contains(path) }
        // The trailing slash keeps /p/no from counting as a parent of /p/notes/a.md.
        let folder = path.hasSuffix("/") ? path : path + "/"
        return paths.contains { $0.hasPrefix(folder) }
    }
}
