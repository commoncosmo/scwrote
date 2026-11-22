import AppKit
import ScwroteCore

/// Reopening a folder where it was left. The window side (frame, panes,
/// dividers, browser) comes back at launch and is saved when the window
/// closes, in every window; the last one to close wins. nvim's side (files,
/// splits, tabs, cursors) is loaded and saved only by the window holding the
/// folder's lock: a second window on the folder leaves it to the first.
extension EditorWindowController {
    /// How long the editor pane stays blank waiting for nvim's side to load.
    private static let coverLimit: Duration = .seconds(2)
    /// How long a save before hanging up may wait for nvim to answer (and
    /// to connect), so closing or quitting is never held up for long.
    nonisolated private static let hangUpSaveTimeout: TimeInterval = 1
    nonisolated private static let hangUpConnectTimeout: TimeInterval = 0.5

    // MARK: - Restoring

    /// The browser at the saved root if it's still a folder, else the
    /// launch's, with the saved open folders and selection that still exist.
    static func browser(restoring saved: WindowState?, launchRoot: String) -> FileBrowser {
        guard let saved else { return FileBrowser(root: launchRoot) }
        var isDirectory: ObjCBool = false
        let root = FileManager.default.fileExists(atPath: saved.browserRoot, isDirectory: &isDirectory)
            && isDirectory.boolValue ? saved.browserRoot : launchRoot
        var browser = FileBrowser(root: root)
        browser.restore(expanded: saved.expanded, selected: saved.selected)
        return browser
    }

    /// The saved panes win over the launch's defaults; on a file launch the
    /// editor, with the named file in front, gets the keyboard.
    static func panes(restoring saved: WindowState?, request: LaunchRequest) -> PaneLayout {
        guard let saved else { return PaneLayout(startsInBrowser: request.startsInBrowser) }
        return PaneLayout(restoring: saved.panes, isFileLaunch: !request.startsInBrowser)
    }

    /// The saved frame, moved onto the screens there are now, and the
    /// dividers' widths. A frame that isn't finite or is smaller than the
    /// window allows (a damaged file) leaves the window centered at its
    /// default size.
    func restoreWindowSide(from saved: WindowState) {
        guard let window else { return }
        let frame = saved.frame
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        if [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
           frame.width >= minimum.width, frame.height >= minimum.height {
            window.setFrame(WindowPlacement.fit(frame, onto: NSScreen.screens.map(\.visibleFrame)), display: false)
        } else {
            window.center()
        }
        if saved.browserWidth.isFinite, saved.browserWidth > 0 { layoutView.browserWidth = saved.browserWidth }
        if saved.previewWidth.isFinite, saved.previewWidth > 0 { layoutView.previewWidth = saved.previewWidth }
    }

    /// Takes the folder's lock; with it, this window keeps nvim's side of
    /// the session, loading it first unless the launch said `--fresh`. Once
    /// nvim has started: loads the session (keeping the editor pane blank
    /// meanwhile, at most `coverLimit`), then sets nvim to save it on exit,
    /// unless someone else's session was already loaded (checked with
    /// `--fresh` too, where nothing is loaded). Loading before the
    /// saver goes in means an nvim quit before the load can't save an empty
    /// session over the folder's. All in one call on the nvim queue, so
    /// nothing asked of nvim meanwhile (a file chosen in the browser) runs
    /// before the load and is then undone by it.
    func startNvimRestore(request: LaunchRequest) {
        do {
            try sessionLock.take(pid: getpid())
            savesNvim = true
            restoresNvim = request.restoresSession
        } catch let held as SessionLock.Held {
            log("another window (process \(held.pid)) has this folder open, so it keeps nvim's session")
            return
        } catch {
            log("couldn't lock \(sessionFolder.lock), so nvim's session is left alone: \(error)")
            return
        }

        if restoresNvim, FileManager.default.fileExists(atPath: sessionFolder.nvimSession) {
            editorContainer.isCovered = true
            Task { [weak self] in
                try? await Task.sleep(for: Self.coverLimit)
                self?.editorContainer.isCovered = false
            }
        }

        let path = sessionFolder.nvimSession
        let restores = restoresNvim
        let namedFiles = request.namedFiles
        Task {
            let outcome = await nvimSetUp(path: path, restores: restores, namedFiles: namedFiles)
            nvimSessionSetUp(outcome)
        }
    }

    private struct NvimSessionOutcome: Sendable {
        /// `.skipped` if someone else's session is loaded, whether or not the
        /// launch restores; nil if nvim couldn't be reached, or a `--fresh`
        /// launch found no session loaded.
        var restore: SessionRestore?
        /// nvim started and the restore, if any, returned.
        var isInPlace = false
        var failure: String?
    }

    private func nvimSetUp(path: String, restores: Bool, namedFiles: [String]) async -> NvimSessionOutcome {
        do {
            return try await nvimCall { nvim in
                var outcome = NvimSessionOutcome()
                do {
                    try nvim.waitUntilStarted()
                } catch {
                    outcome.failure = "couldn't reach nvim: \(error)"
                    return outcome
                }
                if restores {
                    do {
                        outcome.restore = try nvim.restoreSession(from: path, namedFiles: namedFiles)
                    } catch {
                        outcome.restore = .failed("\(error)")
                    }
                } else {
                    do {
                        if try nvim.isSessionLoaded() { outcome.restore = .skipped }
                    } catch {
                        // Not knowing, saving could write over the user's own.
                        outcome.failure = "couldn't ask nvim whether a session is loaded, so it's left alone: \(error)"
                        return outcome
                    }
                }
                outcome.isInPlace = true
                guard outcome.restore != .skipped else { return outcome }
                do {
                    try nvim.installSessionSaver(path: path)
                } catch {
                    outcome.failure = "couldn't set nvim to save the session on exit: \(error)"
                }
                return outcome
            }
        } catch {
            return NvimSessionOutcome(failure: "\(error)")
        }
    }

    private func nvimSessionSetUp(_ outcome: NvimSessionOutcome) {
        editorContainer.isCovered = false
        // Closing hung up on nvim before it was done: nothing to report.
        guard !isClosing else { return }
        switch outcome.restore {
        case .skipped:
            // Someone else's session is loaded (the user's -S, a session
            // plugin): scwrote never writes over what it didn't load.
            savesNvim = false
            isNvimSessionReady = false
            return
        case let .failed(message):
            log("couldn't restore the session: \(message)")
        case .restored, .missing, nil:
            break
        }
        if let failure = outcome.failure { log(failure) }
        // A save before hanging up is safe once nvim's side is in place,
        // even if the saver on exit didn't go in.
        isNvimSessionReady = outcome.isInPlace
    }

    // MARK: - Saving

    /// Before hanging up on a running nvim (closing the window, quitting):
    /// asks nvim to save its side, if this window keeps it and it's in place.
    /// On a connection of its own, so it never waits behind the nvim queue,
    /// giving up after about a second (nvim busy, or at a prompt); a failure
    /// is logged and closing goes on.
    func saveSession() async {
        guard savesNvim, isNvimSessionReady, isNvimRunning else { return }
        let socket = nvimSocket
        let path = sessionFolder.nvimSession
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try NvimClient(
                        socketPath: socket, connectTimeout: Self.hangUpConnectTimeout,
                        readTimeout: Self.hangUpSaveTimeout
                    ).saveSession(to: path)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
        if let failure { log("couldn't save the session before closing: \(failure)") }
    }

    /// Writes the window's side of the session: once, when the window closes
    /// or the app quits with it open. A window in full screen keeps the frame
    /// it had before (that run's, else the one saved last time, else none:
    /// a zero frame, which comes back as the default centered window), so it
    /// never comes back as a screen-sized ordinary window.
    func saveWindowSide() {
        guard !didSaveWindowSide, let window else { return }
        didSaveWindowSide = true
        let browser = browserView.browser
        let frame = window.styleMask.contains(.fullScreen)
            ? frameBeforeFullScreen ?? sessionFolder.readWindowState()?.frame ?? .zero
            : window.frame
        let state = WindowState(
            folder: sessionFolder.root,
            frame: frame,
            panes: panes.saved,
            browserWidth: Double(layoutView.browserWidth),
            previewWidth: Double(layoutView.previewWidth),
            browserRoot: browser.root,
            expanded: browser.expandedFolders,
            selected: browser.selectedPath
        )
        do {
            try sessionFolder.write(state)
        } catch {
            log("couldn't save the window to \(sessionFolder.windowState): \(error)")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("scwrote: \(message)\n".utf8))
    }
}
