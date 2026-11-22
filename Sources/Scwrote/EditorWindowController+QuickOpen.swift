import AppKit
import ScwroteCore

extension EditorWindowController {
    // MARK: - Quick open

    /// Whether quick open lists hidden files (Cmd+Shift+. in the overlay).
    /// scwrote runs one window per process, so the choice lasts until the
    /// window closes.
    static var showsHiddenFiles = true

    var isQuickOpenOpen: Bool { quickOpenView.map { layoutView.overlay === $0 } ?? false }

    /// Closes whichever overlay is open.
    func closeOverlay() {
        closeSearch()
        closeQuickOpen()
    }

    /// Cmd+Shift+O (View menu): open quick open over all the panes, or close
    /// it; from search, switch to it. Without ripgrep it opens only to say
    /// how to get it.
    @objc func toggleQuickOpen(_: Any?) {
        if isQuickOpenOpen {
            closeQuickOpen()
            return
        }
        closeSearch()
        closePrompt()
        let view = quickOpenView ?? makeQuickOpenView()
        let ripgrep = locateRipgrep()
        let files = ripgrep.map { sharedFolderFiles(ripgrep: $0) }
        let root = files?.root ?? FileBrowser.realPath(browserView.browser.root)
        view.root = root
        view.isMissingRipgrep = ripgrep == nil
        layoutView.overlay = view
        window?.makeFirstResponder(view)
        guard let files else { return }

        files.prepare()
        // The overlay has the keyboard, so nvim's buffers can't change while
        // it's open: fetched once per opening, as for search.
        let fetch = OverlayFetch(task: Task {
            (try? await nvimCall { nvim in
                QuickOpenNvimState(
                    recents: try? nvim.recentFiles(under: root),
                    buffers: (try? nvim.unsavedBuffers(under: root)) ?? [], root: root)
            }) ?? QuickOpenNvimState(recents: nil, buffers: [], root: root)
        })
        quickOpenFetch = fetch
        quickOpenSelectsTop = true
        view.reopen()
        // The last opening's selection goes at once, so Enter can't open it:
        // its ranking's rows stand in, the top one selected, while the query
        // is ranked again now with the list as it is (nvim's open and recent
        // files take a moment), and again when nvim answers, keeping the top
        // row selected unless the user has moved. Before the first list:
        // "Listing files…".
        view.results = quickOpenRanked?.results ?? QuickOpenResults()
        rankQuickOpen()
        Task {
            let state = await fetch.task.value
            guard quickOpenFetch === fetch else { return }
            land(state, from: fetch)
            rankQuickOpen()
        }
    }

    /// Gives the keyboard back to the pane that had it.
    func closeQuickOpen() {
        guard isQuickOpenOpen else { return }
        stopQuickOpen()
        layoutView.overlay = nil
        applyPanes()
    }

    /// Drops a ranking in flight and the wait for nvim: also as the window closes.
    func stopQuickOpen() {
        quickOpenGeneration += 1
        quickOpenFetch = nil
    }

    /// The browser's folder's files, shared by search and quick open: made
    /// on first use for the current root. Each list built is sorted into
    /// relative paths once, off the main thread, for quick open.
    func sharedFolderFiles(ripgrep: String) -> FolderFileList {
        if let folderFiles { return folderFiles }
        let files = FolderFileList(ripgrep: ripgrep, root: browserView.browser.root)
        let sorted = SortedSource()
        files.onBuilt = { [weak self, weak files] _ in
            guard let files else { return }
            Self.sortFiles(of: files, last: sorted) { [weak self] paths in self?.folderFilesSorted(paths, from: files) }
        }
        files.onFailed = { [weak self, weak files] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.folderFilesFailed(files) } }
        }
        folderFiles = files
        return files
    }

    /// Sorts `files`' newest list into relative paths on a serial queue and
    /// hands them to `done` on the main thread. Each sort reads the newest
    /// list as it starts, so a late one never brings back an older list. A
    /// list equal to the `last` one sorted (the folder watcher also fires for
    /// ignored build output) is dropped: nothing is sorted or ranked again,
    /// and narrowing carries on.
    private nonisolated static func sortFiles(
        of files: FolderFileList, last: SortedSource, then done: @escaping @MainActor @Sendable ([String]) -> Void
    ) {
        sortQueue.async {
            guard let latest = files.latest, latest != last.paths else { return }
            last.paths = latest
            let prefix = files.root.hasSuffix("/") ? files.root : files.root + "/"
            let paths = latest.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }.sorted()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(paths) } }
        }
    }

    private nonisolated static let sortQueue = DispatchQueue(label: "scwrote.quick-open-sort", qos: .userInitiated)

    /// A new list for the current root: the stale one goes, and an open
    /// quick open ranks again, keeping the selection if its file is listed.
    private func folderFilesSorted(_ paths: [String], from files: FolderFileList) {
        guard files === folderFiles else { return }
        quickOpenFiles = paths
        quickOpenRanked = nil
        if isQuickOpenOpen { rankQuickOpen() }
    }

    /// The list couldn't be built: ripgrep is there but won't run. A quick
    /// open with no list yet says "No files" rather than listing forever;
    /// the next opening tries again, and a list built then replaces it.
    private func folderFilesFailed(_ files: FolderFileList?) {
        guard let files, files === folderFiles, quickOpenFiles == nil else { return }
        FileHandle.standardError.write(Data("scwrote: couldn't run ripgrep to list \(files.root)\n".utf8))
        quickOpenFiles = []
        quickOpenRanked = nil
        if isQuickOpenOpen { rankQuickOpen() }
    }

    private func makeQuickOpenView() -> QuickOpenView {
        let view = QuickOpenView(theme: browserView.theme)
        view.onAction = { [weak self] in self?.handleQuickOpen($0) }
        quickOpenView = view
        return view
    }

    private func handleQuickOpen(_ action: SearchAction<QuickOpenRow>) {
        switch action {
        case .queryChanged: rankQuickOpen()
        case let .open(row): open(row)
        case .close: closeQuickOpen()
        case .toggleHidden:
            Self.showsHiddenFiles.toggle()
            rankQuickOpen()
        }
    }

    private func land(_ state: QuickOpenNvimState, from fetch: OverlayFetch<QuickOpenNvimState>) {
        fetch.value = state
        quickOpenView?.unsaved = state.unsaved
    }

    /// Ranks the query against the list off the main thread (a big folder
    /// takes longer than a frame) and shows the result unless a newer
    /// ranking started meanwhile. A query that extends the last ranked one
    /// scores only its matches. Before the first list: "Listing files…".
    func rankQuickOpen() {
        quickOpenGeneration += 1
        let generation = quickOpenGeneration
        guard isQuickOpenOpen, let view = quickOpenView else { return }
        guard let files = quickOpenFiles else {
            view.results = QuickOpenResults()
            return
        }
        let query = QuickOpenQuery(view.overlay.query.text)
        let root = view.root
        let state = quickOpenFetch?.value
        let showsHidden = Self.showsHiddenFiles
        let previous = quickOpenRanked
        Task.detached(priority: .userInitiated) { [weak self] in
            let ranked = QuickOpenRanking.rank(
                query, root: root, files: files, openFiles: state?.openFiles ?? [], history: state?.history ?? [],
                showsHidden: showsHidden, narrowing: previous)
            await self?.show(ranked, generation: generation)
        }
    }

    /// The first ranking of an opening selects its top row; later ones keep
    /// the selected file if it's still listed.
    private func show(_ ranked: QuickOpenRanked, generation: Int) {
        guard generation == quickOpenGeneration, let view = quickOpenView else { return }
        quickOpenRanked = ranked
        if quickOpenSelectsTop {
            quickOpenSelectsTop = false
            view.results = ranked.results
        } else {
            view.results.replace(with: ranked.results)
        }
    }

    /// Opens the file in nvim, at the query's `:line` if it has one, leaving
    /// nvim's search pattern alone.
    private func open(_ row: QuickOpenRow) {
        let line = QuickOpenQuery(quickOpenView?.overlay.query.text ?? "").line
        closeQuickOpen()
        Task {
            do {
                try await nvimCall { try $0.openFile(row.path, line: line) }
                window?.title = (row.path as NSString).lastPathComponent
                change { $0.openedFile() }
                browserView.reveal(row.path)
            } catch {
                NSSound.beep()
                FileHandle.standardError.write(Data("scwrote: couldn't open \(row.path) in nvim: \(error)\n".utf8))
            }
        }
    }
}

/// The list a folder's last sort started from; touched only on the sort queue.
private final class SortedSource: @unchecked Sendable {
    var paths: Set<String>?
}

/// What quick open asks nvim for as it opens: its open and remembered files
/// under the root, relative to it as ranking takes them, and its unsaved
/// buffers' text by absolute path, for the preview.
struct QuickOpenNvimState: Sendable {
    let openFiles: [String]
    let history: [String]
    let unsaved: [String: String]

    init(recents: RecentFiles?, buffers: [UnsavedBuffer], root: String) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        func relative(_ paths: [String]) -> [String] {
            paths.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        }
        openFiles = relative(recents?.open ?? [])
        history = relative(recents?.history ?? [])
        unsaved = Dictionary(buffers.map { ($0.path, $0.text) }) { _, last in last }
    }
}
