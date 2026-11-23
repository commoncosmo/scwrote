import AppKit
import ScwroteCore

extension EditorWindowController {
    // MARK: - Search

    var isSearchOpen: Bool { searchView.map { layoutView.overlay === $0 } ?? false }

    /// Cmd+Shift+F (View menu): open the search overlay over all the panes,
    /// or close it; from quick open, switch to it. Without ripgrep it opens
    /// only to say how to get it.
    @objc func toggleSearch(_: Any?) {
        if isSearchOpen {
            closeSearch()
            return
        }
        closeQuickOpen()
        closePrompt()
        let view = searchView ?? makeSearchView()
        let root = FileBrowser.realPath(browserView.browser.root)
        view.root = root
        let ripgrep = locateRipgrep()
        view.isMissingRipgrep = ripgrep == nil
        layoutView.overlay = view
        window?.makeFirstResponder(view)
        guard let ripgrep else { return }

        let projectSearch = projectSearch ?? ProjectSearch(ripgrep: ripgrep, files: sharedFolderFiles(ripgrep: ripgrep))
        self.projectSearch = projectSearch
        projectSearch.prepare()
        // The overlay has the keyboard, so nvim's buffers can't change while
        // it's open: fetched once per opening. A search that gave up waiting
        // for them (see `searchBufferWait`) searched the disk alone, so it
        // runs again once they come.
        let fetch = OverlayFetch(task: Task { (try? await nvimCall { try $0.unsavedBuffers(under: root) }) ?? [] })
        searchBuffers = fetch
        Task {
            let buffers = await fetch.task.value
            fetch.value = buffers
            guard searchBuffers === fetch else { return }
            view.unsaved = Dictionary(buffers.map { ($0.path, $0.text) }) { _, last in last }
            if fetch.wasMissed, !buffers.isEmpty { search(view.overlay.query.text) }
        }
        view.reopen()
        search(view.overlay.query.text)
    }

    /// Cancels the search and gives the keyboard back to the pane that had it.
    func closeSearch() {
        guard isSearchOpen else { return }
        stopSearch()
        searchView?.busyMessage = nil
        layoutView.overlay = nil
        applyPanes()
    }

    /// Cancels the search, and one still waiting for nvim's buffers never
    /// starts: also as the window closes.
    func stopSearch() {
        searchGeneration += 1
        projectSearch?.cancel()
        searchBuffers = nil
    }

    /// How long a search waits for nvim's unsaved buffers (and quick open
    /// for its recent files). nvim at a hit-enter or more prompt, a
    /// swap-file question or a long `:!cmd` holds the request; past this the
    /// search goes to the disk alone.
    static let searchBufferWait: Duration = .milliseconds(400)

    /// The bundled ripgrep beside the app's executable, else one on PATH.
    func locateRipgrep() -> String? {
        Ripgrep.locate(
            executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent().path ?? "",
            searchPath: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
    }

    private func makeSearchView() -> SearchOverlayView {
        let view = SearchOverlayView(theme: theme)
        view.onAction = { [weak self] in self?.handle($0) }
        view.onCancelBusy = { [weak self, weak view] in
            guard let self, let view else { return }
            view.busyMessage = nil
            search(view.overlay.query.text)
        }
        searchView = view
        return view
    }

    private func handle(_ action: SearchAction<SearchMatch>) {
        switch action {
        case let .queryChanged(query): search(query)
        case let .open(match): open(match)
        case .close: closeSearch()
        case .toggleHidden: break // quick open only
        case .sendToQuickfix: sendToQuickfix()
        }
    }

    /// Starts over with `query`: the old search stops and its results go at
    /// once. An empty query searches nothing.
    private func search(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        projectSearch?.cancel()
        searchView?.results = SearchResults()
        guard !query.isEmpty, let projectSearch, let fetch = searchBuffers else { return }
        Task { [weak self] in
            var buffers = fetch.value
            if buffers == nil { buffers = await valueIfQuick(of: fetch.task, within: Self.searchBufferWait) }
            guard let self, generation == searchGeneration else { return }
            // The fetch may have landed while this waited to run.
            buffers = buffers ?? fetch.value
            if buffers == nil { fetch.wasMissed = true }
            projectSearch.search(query, buffers: buffers ?? [], onBatch: { [weak self] batch in
                guard let self, generation == searchGeneration else { return }
                searchView?.results.add(batch)
            }, onFinish: { [weak self] in
                guard let self, generation == searchGeneration else { return }
                searchView?.results.finish()
            })
        }
    }

    /// Ctrl-Q: runs the query again without the overlay's cap, over the same
    /// unsaved buffers, and hands every matching line to nvim as a new
    /// quickfix list. The overlay says so meanwhile; Esc, or closing it,
    /// cancels. A finished search with no matches sends nothing. Unlike the
    /// overlay's own search, this waits as long as nvim takes to give its
    /// unsaved buffers: a list for `:cfdo` must not quietly be the disk's.
    private func sendToQuickfix() {
        guard let view = searchView, let projectSearch, let fetch = searchBuffers else { return }
        if view.results.isFinished, view.results.matches.isEmpty { return }
        let query = view.overlay.query.text
        searchGeneration += 1
        let generation = searchGeneration
        view.busyMessage = "Sending to quickfix…"
        let collected = QuickfixMatches()
        Task { [weak self] in
            let buffers = await fetch.task.value
            guard let self, generation == searchGeneration else { return }
            projectSearch.search(query, buffers: buffers, limit: nil, onBatch: { [weak self] batch in
                guard let self, generation == searchGeneration else { return }
                collected.matches.append(contentsOf: batch)
            }, onFinish: { [weak self] in
                guard let self, generation == searchGeneration else { return }
                handOver(collected.sorted, query: query)
            })
        }
    }

    /// Closes the overlay and gives nvim the list, then follows it to the
    /// first match as opening one does.
    private func handOver(_ matches: [SearchMatch], query: String) {
        searchView?.busyMessage = nil
        guard let first = matches.first else {
            // The overlay's own search was replaced by this one before it
            // finished: it found nothing either, so say so.
            searchView?.results.finish()
            return
        }
        closeSearch()
        Task {
            do {
                try await nvimCall { try $0.sendToQuickfix(matches, query: query) }
                window?.title = (first.path as NSString).lastPathComponent
                change { $0.openedFile() }
                browserView.reveal(first.path)
            } catch {
                NSSound.beep()
                FileHandle.standardError.write(Data("scwrote: couldn't send the matches to nvim: \(error)\n".utf8))
            }
        }
    }

    /// Opens the match in nvim at its line and column, with the query as the
    /// `/` pattern, the way the browser opens a file.
    private func open(_ match: SearchMatch) {
        let query = searchView?.overlay.query.text ?? ""
        closeSearch()
        Task {
            do {
                try await nvimCall { try $0.open(match.path, line: match.line, column: match.column, query: query) }
                window?.title = (match.path as NSString).lastPathComponent
                change { $0.openedFile() }
                browserView.reveal(match.path)
            } catch {
                NSSound.beep()
                FileHandle.standardError.write(Data("scwrote: couldn't open \(match.path) in nvim: \(error)\n".utf8))
            }
        }
    }
}

/// The matches an uncapped search delivers, in arrival order until sorted.
@MainActor
private final class QuickfixMatches {
    var matches: [SearchMatch] = []

    /// File then line, one per line.
    var sorted: [SearchMatch] {
        var seen = Set<SearchMatch.Key>()
        return matches.sorted { $0.key < $1.key }.filter { seen.insert($0.key).inserted }
    }
}

/// What one opening of an overlay asks nvim for: search's unsaved buffers,
/// quick open's recent files and unsaved buffers.
@MainActor
final class OverlayFetch<Value: Sendable> {
    let task: Task<Value, Never>
    /// Set once `task` has finished.
    var value: Value?
    /// The overlay went ahead without it, nvim being slow to answer.
    var wasMissed = false

    init(task: Task<Value, Never>) {
        self.task = task
    }
}

/// `task`'s value, or nil if it takes longer than `limit`. Stops waiting at
/// the limit; `task` itself keeps running for whoever else awaits it.
@MainActor
func valueIfQuick<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
    let first = FirstResult<T>()
    return await withCheckedContinuation { continuation in
        first.continuation = continuation
        Task { @MainActor in first.resume(await task.value) }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            first.resume(nil)
        }
    }
}

/// Resumes its continuation once, with whichever result comes first.
@MainActor
private final class FirstResult<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?

    func resume(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
