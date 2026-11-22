import CryptoKit
import Foundation

/// Where each project folder's saved session lives: one subfolder per project
/// folder under `directory`.
public struct SessionStore: Sendable {
    public let directory: String

    /// `SCWROTE_SESSIONS_DIR` if set, else `~/Library/Application Support/scwrote/sessions`.
    public init(environment: [String: String], home: String) {
        directory =
            environment["SCWROTE_SESSIONS_DIR"] ?? home + "/Library/Application Support/scwrote/sessions"
    }

    /// The session folder for a project folder, keyed by the SHA-256 of its
    /// real path so a symlink to it finds the same session.
    public func folder(for root: String) -> SessionFolder {
        let real = FileBrowser.realPath(root)
        let key = SHA256.hash(data: Data(real.utf8)).map { String(format: "%02x", $0) }.joined()
        return SessionFolder(path: directory + "/" + key, root: real)
    }
}

/// One project folder's session: the window's state, nvim's session file and
/// the lock.
public struct SessionFolder: Sendable {
    public let path: String
    private let root: String

    init(path: String, root: String) {
        self.path = path
        self.root = root
    }

    public var windowState: String { path + "/window.json" }
    public var nvimSession: String { path + "/session.vim" }
    public var lock: String { path + "/lock" }

    /// The saved window state, or nil if there is none, it can't be read, it's
    /// of another version, or it's for another folder.
    public func readWindowState() -> WindowState? {
        guard let data = FileManager.default.contents(atPath: windowState),
            let state = try? JSONDecoder().decode(WindowState.self, from: data),
            state.version == WindowState.version,
            FileBrowser.realPath(state.folder) == root
        else { return nil }
        return state
    }

    /// Saves the state, creating the session folder; the file is replaced
    /// atomically, so a crash never leaves half of one.
    public func write(_ state: WindowState) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: URL(fileURLWithPath: windowState), options: .atomic)
    }
}

/// A file holding the process ID of the window that has a folder open, so a
/// second window on the same folder can tell.
public struct SessionLock: Sendable {
    private let path: String

    public init(path: String) { self.path = path }

    /// The process holding the lock, if it's still running.
    public func holder() -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
    }

    /// Another live process holds the lock.
    public struct Held: Error, Equatable {
        public let pid: pid_t
        public init(pid: pid_t) { self.pid = pid }
    }

    /// Records `pid` as the holder. The file is created exclusively, so of two
    /// windows racing for a folder only one succeeds: the other gets `Held`.
    /// Succeeds if `pid` already holds it, and takes over a lock left by a
    /// process that's gone.
    public func take(pid: pid_t) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if try create(pid) { return }
        if let live = holder() {
            if live == pid { return }
            throw Held(pid: live)
        }
        try? FileManager.default.removeItem(atPath: path)
        if try create(pid) { return }
        if let live = holder(), live != pid { throw Held(pid: live) }
    }

    /// Creates the lock file holding `pid`; false if it already exists.
    private func create(_ pid: pid_t) throws -> Bool {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(fd) }
        let bytes = Array(String(pid).utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
        return true
    }

    /// Gives up the lock, but only if `pid` holds it.
    public func release(pid: pid_t) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == pid
        else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
