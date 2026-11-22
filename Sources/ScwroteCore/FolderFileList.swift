import Foundation

/// One folder's files, as `rg --files --hidden` lists them (ignore rules
/// apply, `.git` is left out), in nvim's path form. Shared by project search
/// and quick open. Create a new one when the root changes.
///
/// Threading: any method may be called from any thread; ripgrep callbacks
/// arrive on a background thread. All state is under `lock`. Nothing here
/// calls `RipgrepRun.cancel()` or a caller's closure while holding `lock`:
/// `whenReady` bodies and `onBuilt` are always dispatched to a background
/// queue, never run on the caller's stack, so a caller may ask for the list
/// while holding its own lock without deadlocking.
public final class FolderFileList: @unchecked Sendable {
    /// Resolved, so listed paths are in nvim's form.
    public let root: String
    private let ripgrep: String
    private let lock = NSLock()

    /// The list, or nil until built (or after a change).
    private var fileList: Set<String>?
    /// The last list built, kept through `invalidate()` for readers that
    /// prefer a moment-old list to none.
    private var lastBuilt: Set<String>?
    private var listRun: RipgrepRun?
    /// Names the latest list build, so a dropped build's late result is ignored.
    private var listGeneration = 0
    /// The folder changed while `listRun` was building: its list is fed to
    /// waiters but not kept as fresh, and one new build starts when it ends.
    private var listDirty = false
    /// Bodies waiting for the running build. Non-empty only while `listRun` runs.
    private var waiters: [@Sendable (Set<String>) -> Void] = []
    private var builtHandler: (@Sendable (Set<String>) -> Void)?

    public init(ripgrep: String, root: String) {
        self.ripgrep = ripgrep
        self.root = FileBrowser.realPath(root)
    }

    deinit {
        listRun?.cancel()
    }

    /// Called after each completed build, on a background queue, outside the lock.
    public var onBuilt: (@Sendable (Set<String>) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return builtHandler }
        set { lock.lock(); defer { lock.unlock() }; builtHandler = newValue }
    }

    /// The last list built, or nil before the first build finishes. Kept
    /// through `invalidate()` until a newer build replaces it.
    public var latest: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return lastBuilt
    }

    /// Whether any `/`-separated component of `relativePath` starts with `.`.
    public static func isHidden(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Builds the list in the background if there's no fresh one and no build running.
    public func prepare() {
        lock.lock()
        defer { lock.unlock() }
        if fileList == nil && listRun == nil { buildFileList() }
    }

    /// FolderWatcher saw a change. Drops the list, so the next
    /// prepare/whenReady rebuilds it. A build already running is left to
    /// finish rather than restarted: the watcher also fires for ignored
    /// output (.build, node_modules), and restarting on every event would
    /// starve a build slower than the gap between events, leaving its waiters
    /// unfed. That build's moment-old list still feeds them; changes during
    /// it coalesce into one rebuild after it.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if listRun != nil {
            listDirty = true
        } else {
            fileList = nil
        }
    }

    /// Calls `body` with the list on a background queue: soon if there's a
    /// fresh one, else when the running or next build ends. If the build
    /// can't start, `body` gets an empty list (so a waiting search still
    /// finishes) and the list stays unbuilt, so the next call tries again.
    public func whenReady(_ body: @escaping @Sendable (Set<String>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let fileList {
            Self.deliver(fileList, to: [body])
            return
        }
        waiters.append(body)
        if listRun == nil { buildFileList() }
    }

    // MARK: - Under `lock`

    private func buildFileList() {
        listGeneration += 1
        listDirty = false
        let build = listGeneration
        let root = root
        let paths = PathCollector()
        do {
            listRun = try RipgrepRun(
                executable: ripgrep, arguments: Ripgrep.fileListArguments, directory: root, stdin: nil,
                // Both callbacks run on the run's one reader thread, one after the other.
                onLine: { paths.items.insert(root + "/" + String(decoding: $0, as: UTF8.self)) },
                onExit: { [weak self] in self?.fileListBuilt(paths.items, build: build) })
        } catch {
            listRun = nil
            let fed = waiters
            waiters = []
            Self.deliver([], to: fed)
        }
    }

    /// Hands `paths` to `bodies` on a background queue, so none runs on the
    /// caller's stack or under `lock`.
    private static func deliver(_ paths: Set<String>, to bodies: [@Sendable (Set<String>) -> Void]) {
        guard !bodies.isEmpty else { return }
        DispatchQueue.global().async {
            bodies.forEach { $0(paths) }
        }
    }

    // MARK: - From the build's reader thread

    private func fileListBuilt(_ paths: Set<String>, build: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard build == listGeneration else { return }
        listRun = nil
        lastBuilt = paths
        let fed = waiters
        waiters = []
        if listDirty {
            buildFileList()
        } else {
            fileList = paths
        }
        Self.deliver(paths, to: fed + (builtHandler.map { [$0] } ?? []))
    }
}

/// The file list as its run reads it; touched only on that run's reader thread.
private final class PathCollector: @unchecked Sendable {
    var items: Set<String> = []
}
