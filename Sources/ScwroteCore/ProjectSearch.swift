import Foundation

/// A modified buffer, searched from its text instead of the file on disk.
public struct UnsavedBuffer: Equatable, Sendable {
    /// Absolute, in nvim's form (folders resolved, as `FileBrowser.nvimPath(of:)`).
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// Searches one folder. Create a new one when the root changes.
///
/// Runs ripgrep over the folder, plus one stdin run per unsaved buffer whose
/// file is in the folder's file list (`rg --files`, so a buffer counts by the
/// same ignore rules as the disk). Results reach the main queue in batches.
///
/// Threading: `search` and `cancel` are called on the main thread; ripgrep
/// callbacks arrive on background threads. All state is under `lock`. Nothing
/// calls `RipgrepRun.cancel()` while holding `lock` (a run's callback may be
/// waiting for it, and `cancel()` waits for that callback), and nothing here
/// ever waits on the main thread: callbacks hop there with `async` only, and
/// every delivery checks the generation so a cancelled search never delivers.
public final class ProjectSearch: @unchecked Sendable {
    /// A batch goes to the main queue once it has this many matches...
    static let batchSize = 200
    /// ...or this long after its first match arrived.
    static let batchDelay: DispatchTimeInterval = .milliseconds(50)
    /// One past the cap, so `SearchResults` sees the overflow and says "1000+".
    static let deliveryLimit = SearchResults.cap + 1

    private let ripgrep: String
    /// Resolved, so disk results are in nvim's path form.
    private let root: String
    private let lock = NSLock()

    /// Bumped by every `search` and `cancel`; deliveries for older ones are dropped.
    private var generation = 0
    private var current: Search?

    /// Paths in nvim's form, or nil until built (or after a change).
    private var fileList: Set<String>?
    private var listRun: RipgrepRun?
    /// Names the latest list build, so a dropped build's late result is ignored.
    private var listGeneration = 0
    /// The folder changed while `listRun` was building: its list is fed to a
    /// waiting search but not kept, and one new build starts when it ends.
    private var listDirty = false

    public init(ripgrep: String, root: String) {
        self.ripgrep = ripgrep
        self.root = FileBrowser.realPath(root)
    }

    deinit {
        cancel()
        listRun?.cancel()
    }

    /// Builds the file list in the background if there isn't one.
    public func prepare() {
        lock.lock()
        defer { lock.unlock() }
        if fileList == nil && listRun == nil { buildFileList() }
    }

    /// FolderWatcher saw a change. Drops the file list, so the next
    /// prepare/search rebuilds it. A build already running is left to finish
    /// rather than restarted: the watcher also fires for ignored output
    /// (.build, node_modules), and restarting on every event would starve a
    /// build slower than the gap between events, leaving a waiting search
    /// unfinished. That build's moment-old list still feeds the waiting
    /// search; changes during it coalesce into one rebuild after it.
    public func invalidateFileList() {
        lock.lock()
        defer { lock.unlock() }
        if listRun != nil {
            listDirty = true
        } else {
            fileList = nil
        }
    }

    /// Cancels the running search, then searches `query` (non-empty).
    /// Disk results for any path in `buffers` are dropped. Each buffer whose
    /// path is in the file list is searched from its text, once the list is ready.
    /// `onBatch` and `onFinish` run on the main queue, only for this search.
    public func search(_ query: String, buffers: [UnsavedBuffer],
                       onBatch: @escaping @MainActor ([SearchMatch]) -> Void,
                       onFinish: @escaping @MainActor () -> Void) {
        lock.lock()
        let previous = stopCurrent()
        let search = Search(generation: generation, query: query, buffers: buffers,
                            onBatch: onBatch, onFinish: onFinish)
        current = search

        let root = root
        let bufferPaths = Set(buffers.map(\.path))
        start(search, arguments: Ripgrep.searchArguments(query, stdin: false), stdin: nil) { line in
            guard let match = RipgrepJSON.match(from: line, root: root),
                  !bufferPaths.contains(match.path) else { return nil }
            return match
        }
        if let fileList {
            startBufferRuns(search, fileList: fileList)
        } else {
            search.awaitingList = true
            if listRun == nil { buildFileList() }
        }
        finishIfDone(search)
        lock.unlock()
        previous.forEach { $0.cancel() }
    }

    public func cancel() {
        lock.lock()
        let previous = stopCurrent()
        lock.unlock()
        previous.forEach { $0.cancel() }
    }

    // MARK: - Under `lock`

    /// Ends the current search and returns its runs, for the caller to cancel
    /// once it has let go of `lock`.
    private func stopCurrent() -> [RipgrepRun] {
        generation += 1
        defer { current = nil }
        guard let search = current, !search.isOver else { return [] }
        search.isOver = true
        return search.runs
    }

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
            // The list stays nil, so the next prepare/search tries again. A
            // waiting search goes on without its buffers rather than never finishing.
            listRun = nil
            feedWaitingSearch([])
        }
    }

    private func fileListBuilt(_ paths: Set<String>, build: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard build == listGeneration else { return }
        listRun = nil
        feedWaitingSearch(paths)
        if listDirty {
            buildFileList()
        } else {
            fileList = paths
        }
    }

    /// Starts the buffer runs of a search that was waiting for the list.
    private func feedWaitingSearch(_ paths: Set<String>) {
        guard let search = current, search.awaitingList, !search.isOver else { return }
        search.awaitingList = false
        startBufferRuns(search, fileList: paths)
        finishIfDone(search)
    }

    private func startBufferRuns(_ search: Search, fileList: Set<String>) {
        let root = root
        let arguments = Ripgrep.searchArguments(search.query, stdin: true)
        for buffer in search.buffers where fileList.contains(buffer.path) {
            start(search, arguments: arguments, stdin: Data(buffer.text.utf8)) { line in
                RipgrepJSON.match(from: line, root: root, label: buffer.path)
            }
        }
    }

    /// Starts one ripgrep run for `search`; `parse` turns an output line into
    /// a match to deliver, or nil. A run that can't start counts as done.
    private func start(_ search: Search, arguments: [String], stdin: Data?,
                       parse: @escaping @Sendable (Data) -> SearchMatch?) {
        do {
            let run = try RipgrepRun(
                executable: ripgrep, arguments: arguments, directory: root, stdin: stdin,
                onLine: { [weak self] line in
                    // Parsed before taking the lock, so runs parse in parallel.
                    guard let self, let match = parse(line) else { return }
                    self.received(match, for: search)
                },
                onExit: { [weak self] in self?.exited(search) })
            search.runs.append(run)
            search.running += 1
        } catch {}
    }

    private func finishIfDone(_ search: Search) {
        guard !search.isOver, search.running == 0, !search.awaitingList else { return }
        end(search)
    }

    /// Delivers what's left, then `onFinish`, for a search that's done or capped.
    private func end(_ search: Search) {
        search.isOver = true
        flush(search)
        let generation = search.generation
        let onFinish = search.onFinish
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            onFinish()
        }
    }

    private func flush(_ search: Search) {
        guard !search.pending.isEmpty else { return }
        let batch = search.pending
        search.pending = []
        let generation = search.generation
        let onBatch = search.onBatch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            onBatch(batch)
        }
    }

    // MARK: - From ripgrep callbacks (background threads)

    private func received(_ match: SearchMatch, for search: Search) {
        lock.lock()
        guard !search.isOver, search.seen.insert(match.key).inserted else {
            lock.unlock()
            return
        }
        search.pending.append(match)
        if search.seen.count >= Self.deliveryLimit {
            end(search)
            let runs = search.runs
            lock.unlock()
            runs.forEach { $0.cancel() }
            return
        }
        if search.pending.count >= Self.batchSize {
            flush(search)
        } else if !search.flushScheduled {
            search.flushScheduled = true
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                search.flushScheduled = false
                if !search.isOver { self.flush(search) }
            }
        }
        lock.unlock()
    }

    private func exited(_ search: Search) {
        lock.lock()
        defer { lock.unlock() }
        guard !search.isOver else { return }
        search.running -= 1
        finishIfDone(search)
    }

    /// Main queue: whether a delivery for `generation` still has a listener.
    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }
}

/// One call to `search`. Every `var` is guarded by its `ProjectSearch`'s lock.
private final class Search: @unchecked Sendable {
    let generation: Int
    let query: String
    let buffers: [UnsavedBuffer]
    let onBatch: @MainActor ([SearchMatch]) -> Void
    let onFinish: @MainActor () -> Void

    var runs: [RipgrepRun] = []
    /// Runs started that haven't exited.
    var running = 0
    /// Buffer runs wait for the file list.
    var awaitingList = false
    /// Finished, capped or cancelled: nothing more is delivered or started.
    var isOver = false
    /// Keys delivered (or about to be), to count toward the cap.
    var seen: Set<SearchMatch.Key> = []
    var pending: [SearchMatch] = []
    var flushScheduled = false

    init(generation: Int, query: String, buffers: [UnsavedBuffer],
         onBatch: @escaping @MainActor ([SearchMatch]) -> Void,
         onFinish: @escaping @MainActor () -> Void) {
        self.generation = generation
        self.query = query
        self.buffers = buffers
        self.onBatch = onBatch
        self.onFinish = onFinish
    }
}

/// The file list as its run reads it; touched only on that run's reader thread.
private final class PathCollector: @unchecked Sendable {
    var items: Set<String> = []
}
