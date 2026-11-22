import AppKit
import ScwroteCore

extension EditorWindowController {
    // MARK: - Search

    var isSearchOpen: Bool { layoutView.overlay != nil }

    /// Cmd+Shift+F (View menu): open the search overlay over all the panes,
    /// or close it. Without ripgrep it opens only to say how to get it.
    @objc func toggleSearch(_: Any?) {
        if isSearchOpen {
            closeSearch()
            return
        }
        closePrompt()
        let view = searchView ?? makeSearchView()
        let root = FileBrowser.realPath(browserView.browser.root)
        view.root = root
        let ripgrep = Ripgrep.locate(
            executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent().path ?? "",
            searchPath: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
        view.isMissingRipgrep = ripgrep == nil
        layoutView.overlay = view
        window?.makeFirstResponder(view)
        guard let ripgrep else { return }

        let projectSearch = projectSearch ?? ProjectSearch(ripgrep: ripgrep, root: root)
        self.projectSearch = projectSearch
        projectSearch.prepare()
        // The overlay has the keyboard, so nvim's buffers can't change while
        // it's open: fetched once, and every search waits for them.
        let fetch = Task { (try? await nvimCall { try $0.unsavedBuffers(under: root) }) ?? [] }
        searchBuffers = fetch
        Task {
            let buffers = await fetch.value
            guard searchBuffers == fetch else { return }
            view.unsaved = Dictionary(buffers.map { ($0.path, $0.text) }) { _, last in last }
        }
        view.reopen()
        search(view.overlay.query.text)
    }

    /// Cancels the search and gives the keyboard back to the pane that had it.
    func closeSearch() {
        guard isSearchOpen else { return }
        searchGeneration += 1
        projectSearch?.cancel()
        searchBuffers = nil
        layoutView.overlay = nil
        applyPanes()
    }

    private func makeSearchView() -> SearchOverlayView {
        let view = SearchOverlayView(theme: browserView.theme)
        view.onAction = { [weak self] in self?.handle($0) }
        searchView = view
        return view
    }

    private func handle(_ action: SearchAction) {
        switch action {
        case let .queryChanged(query): search(query)
        case let .open(match): open(match)
        case .close: closeSearch()
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
            let buffers = await fetch.value
            guard let self, generation == searchGeneration else { return }
            projectSearch.search(query, buffers: buffers, onBatch: { [weak self] batch in
                guard let self, generation == searchGeneration else { return }
                searchView?.results.add(batch)
            }, onFinish: { [weak self] in
                guard let self, generation == searchGeneration else { return }
                searchView?.results.finish()
            })
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
