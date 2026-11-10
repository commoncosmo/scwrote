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
        // Events come on the listener's thread; the main queue keeps their order.
        previewEvents.start(
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
            },
            onEnd: {}
        )
    }

    private func receive(_ event: PreviewEvent) {
        switch event {
        case let .buffer(snapshot): latestCursor = (snapshot.path, snapshot.cursor)
        case let .cursor(path, position): latestCursor = (path, position)
        case .modified: break
        }
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

    /// The preview was just shown: render what changed while it was hidden,
    /// at its real size, then go to nvim's cursor.
    func previewAppeared() {
        layoutView.layoutSubtreeIfNeeded()
        if isPreviewOutOfDate { renderPreview() }
        followCursorInPreview()
    }

    /// The keyboard came back to the editor: the preview goes back to nvim's
    /// buffer, and following picks up at once.
    func previewReturnedToEditor() {
        let effect = previewState.returnToEditor()
        applyPreview(effect)
        // A render already followed.
        if effect != .render, panes.isPreviewShown { followCursorInPreview() }
    }

    private func renderPreview() {
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
