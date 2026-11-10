import AppKit
import ScwroteCore

extension EditorWindowController {
    // MARK: - File actions

    /// A window shortcut or a move to another folder: the prompt closes, and a
    /// delete question still waiting on nvim won't open. The shortcuts reach
    /// the window before the browser, so the browser can't see them itself.
    func closePrompt() {
        browserView.prompt = nil
        pendingDelete = nil
        browserView.isWaitingForPrompt = false
    }

    /// Opens the delete question once nvim has said whether the item, or
    /// anything inside it, has unsaved changes. nvim is asked rather than the
    /// browser's dots, which only follow plain file buffers: a plugin's
    /// buffer (an encrypted file) holds edits too, and deleting discards
    /// them. No answer within a second counts as unsaved, so the question is
    /// the stronger one rather than a wait.
    func askToDelete(_ path: String) {
        let token = UUID()
        pendingDelete = token
        browserView.isWaitingForPrompt = true
        let nvimPath = FileBrowser.nvimPath(of: path)
        let root = browserView.browser.root
        Task {
            let modified = (try? await nvimCall { try $0.hasModifiedBuffers(at: nvimPath) }) ?? true
            openDeleteQuestion(token, path: path, root: root, hasUnsavedChanges: modified)
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            openDeleteQuestion(token, path: path, root: root, hasUnsavedChanges: true)
        }
    }

    /// The first of nvim's answer and the deadline opens the question, unless
    /// the browser moved on while it waited: another `d`, another prompt,
    /// folder or row, or the keyboard elsewhere.
    private func openDeleteQuestion(_ token: UUID, path: String, root: String, hasUnsavedChanges: Bool) {
        guard pendingDelete == token else { return }
        pendingDelete = nil
        browserView.isWaitingForPrompt = false
        let browser = browserView.browser
        guard browserView.prompt == nil, browser.root == root, browser.selectedEntry?.path == path,
              window?.firstResponder === browserView
        else { return }
        let question = fileActions.deleteQuestion(for: path, hasUnsavedChanges: hasUnsavedChanges)
        browserView.prompt = .delete(path: path, question: question)
    }

    /// Carries out what the prompt asked for. A refused or failed action
    /// leaves the prompt open with the reason; otherwise it closes, and the
    /// browser shows the result at once rather than waiting for the folder
    /// watcher.
    func finishPrompt(_ outcome: BrowserPrompt.Outcome) {
        guard let prompt = browserView.prompt else { return }
        switch (prompt.kind, outcome) {
        case let (.add(folder), .submitted(name)):
            switch fileActions.create(name, in: folder) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case let .success(item): added(item)
            }
        case let (.rename(path), .submitted(name)):
            // Resolved now: once the item has moved there's nothing to resolve.
            let oldNvimPath = FileBrowser.nvimPath(of: path)
            switch fileActions.rename(path, to: name) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case .success(nil): browserView.prompt = nil
            case let .success(newPath?): renamed(from: oldNvimPath, to: newPath)
            }
        case let (.delete(path, _), .confirmed):
            let nvimPath = FileBrowser.nvimPath(of: path)
            switch fileActions.delete(path) {
            case let .failure(error): browserView.prompt?.fail(error.message)
            case .success: deleted(nvimPath: nvimPath)
            }
        default:
            browserView.prompt = nil
        }
    }

    /// A new file opens as if chosen; a new folder is selected.
    private func added(_ item: NewItem) {
        browserView.prompt = nil
        browserView.reload()
        browserView.reveal(item.path)
        if !item.isFolder { choose(item.path) }
    }

    /// nvim's buffers take the new name, keeping unsaved changes.
    private func renamed(from oldNvimPath: String, to newPath: String) {
        browserView.prompt = nil
        browserView.reload()
        browserView.reveal(newPath)
        let newNvimPath = FileBrowser.nvimPath(of: newPath)
        syncNvim("follow the rename of \(oldNvimPath)") { try $0.renameBuffers(from: oldNvimPath, to: newNvimPath) }
    }

    /// The cursor stays where the item was (on the row that took its place).
    private func deleted(nvimPath: String) {
        browserView.prompt = nil
        browserView.reload()
        syncNvim("close the buffers of \(nvimPath)") { try $0.closeBuffers(at: nvimPath) }
    }

    /// The disk change stands even if nvim can't follow it, so a failure is
    /// only reported: a beep, and the first line on stderr (nvim's own
    /// message, without the Lua traceback after it).
    private func syncNvim(_ what: String, _ work: @escaping @Sendable (NvimClient) throws -> Void) {
        Task {
            do {
                try await nvimCall(work)
            } catch {
                NSSound.beep()
                let message: String = if case let NvimClient.Failure.nvim(text) = error { text } else { "\(error)" }
                let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
                FileHandle.standardError.write(Data("scwrote: nvim couldn't \(what): \(firstLine)\n".utf8))
            }
        }
    }
}
