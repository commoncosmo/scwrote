import AppKit
import ScwroteCore

/// The preview's side of the window: nvim's events go into `previewState`,
/// and what it says to do goes to `previewView`.
extension EditorWindowController {
    /// Hooks up the preview pane and starts listening to nvim. Once, from init.
    func connectPreview() {
        previewView.onLeave = { [weak self] in self?.change { $0.leavePreview() } }
        previewView.onClick = { [weak self] in self?.change { $0.clicked(.preview) } }
        previewView.onOpenLink = { [weak self] in self?.choose($0) }
        previewView.onRendered = { [weak self] error, note in
            guard let self else { return }
            previewState.rendered(error: error, note: note)
            previewView.showHeader(previewState.header)
        }
        // Events come on the listener's thread and wait in the inbox, in order,
        // for one hop to the main queue; a newer text for the same file
        // replaces one still waiting there.
        let inbox = PreviewEventInbox()
        previewEvents.start(
            onEvent: { [weak self] event in
                guard inbox.post(event) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for event in inbox.take() { self?.receive(event) }
                    }
                }
            },
            onEnd: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.previewEventsEnded() } }
            }
        )
    }

    /// The listener stops for good when nvim goes away; while the window is
    /// still open that means the preview no longer follows nvim, so say why.
    private func previewEventsEnded() {
        guard !isClosing else { return }
        FileHandle.standardError.write(Data("scwrote: lost nvim's events; the preview no longer follows nvim\n".utf8))
    }

    /// Colors recolor the window, and ownership of `background` goes to the
    /// appearance mode; neither goes further: they mean nothing to the
    /// browser's unsaved marks or the preview's state.
    private func receive(_ event: PreviewEvent) {
        switch event {
        case let .buffer(snapshot): latestCursor = (snapshot.path, snapshot.cursor)
        case let .cursor(path, position): latestCursor = (path, position)
        case let .colors(report):
            receiveColors(report)
            return
        case let .backgroundOwner(owned):
            backgroundOwnerKnown(owned: owned)
            return
        case .modified, .unsaved: break
        }
        var unsaved = browserView.unsaved
        if unsaved.apply(event) { browserView.unsaved = unsaved }
        applyPreview(previewState.apply(event))
    }

    /// Carries out what the preview state asked for. A hidden preview does no
    /// work: it is only marked out of date, and catches up when shown.
    func applyPreview(_ effect: PreviewEffect) {
        guard panes.isPreviewShown else {
            if effect == .render || effect == .headerOnly { isPreviewOutOfDate = true }
            return
        }
        switch effect {
        case .render:
            renderPreview()
        case .headerOnly:
            previewView.showHeader(previewState.header)
        case let .follow(cursor):
            // While the preview has the keyboard, it stays where the user put it.
            if panes.isPreviewShown, panes.focus != .preview {
                previewView.follow(cursor, lineCount: previewLineCount)
            }
        case .nothing:
            break
        }
    }

    /// The preview was just shown: ask nvim for the text it left out while
    /// the preview was hidden, render what changed at the preview's real
    /// size, then go to nvim's cursor.
    func previewAppeared() {
        previewEvents.setSendsText(true)
        layoutView.layoutSubtreeIfNeeded()
        if isPreviewOutOfDate { renderPreview() }
        followCursorInPreview()
    }

    /// The preview was hidden: nvim stops building text for it.
    func previewDisappeared() {
        previewEvents.setSendsText(false)
    }

    /// The keyboard came back to the editor: the preview goes back to nvim's
    /// buffer, and following picks up at once.
    func previewReturnedToEditor() {
        let effect = previewState.returnToEditor()
        applyPreview(effect)
        // A render already followed.
        if effect != .render, panes.isPreviewShown { followCursorInPreview() }
    }

    /// Renders the target, unless its text is still on the way: then only the
    /// header changes, and the render waits for the buffer event that brings
    /// the text.
    private func renderPreview() {
        if previewState.isAwaitingText {
            previewView.showHeader(previewState.header)
            isPreviewOutOfDate = true
            return
        }
        isPreviewOutOfDate = false
        if case let .buffer(snapshot) = previewState.target {
            previewLineCount = snapshot.lineCount
        } else {
            previewLineCount = 1
        }
        previewView.show(previewState)
        previewView.showHeader(previewState.header)
        if panes.focus != .preview { followCursorInPreview() }
    }

    /// Scrolls the preview to nvim's newest cursor in the shown buffer.
    func followCursorInPreview() {
        guard case let .buffer(snapshot) = previewState.target else { return }
        let cursor = latestCursor.flatMap { $0.path == snapshot.path ? $0.position : nil } ?? snapshot.cursor
        previewView.follow(cursor, lineCount: previewLineCount)
    }

    /// An image or PDF chosen in the browser or by a link: shown in the
    /// preview, shown even if hidden, while nvim and the keyboard stay put.
    /// Picked first, so a preview that this shows renders the file once.
    func showViewOnly(_ path: String) {
        applyPreview(previewState.pickViewOnly(path))
        change { $0.openedViewOnlyFile() }
    }
}
