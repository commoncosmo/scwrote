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
    /// The project folder's real path.
    public let root: String

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

/// An OS lock (flock) on a file, held for as long as the window lives, so
/// two windows can't have one folder open and a closed or crashed window never
/// leaves a lock behind. Not thread-safe: use it from one actor.
public final class SessionLock: @unchecked Sendable {
    /// Another process holds the lock; `pid` is what it wrote, 0 if unreadable.
    public struct Held: Error, Equatable {
        public let pid: pid_t
        public init(pid: pid_t) { self.pid = pid }
    }

    private let path: String
    private var fd: Int32 = -1

    public init(path: String) { self.path = path }

    deinit { release() }

    /// Takes the lock and writes `pid` into the file (for diagnostics only).
    /// Throws `Held` if another open file description holds it. A no-op if this
    /// instance already holds it. The file is never deleted, so everyone locks
    /// the same inode.
    public func take(pid: pid_t) throws {
        if fd >= 0 { return }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard opened >= 0 else { throw CocoaError(.fileWriteUnknown) }
        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let reason = errno
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = read(opened, &buffer, buffer.count)
            close(opened)
            guard reason == EWOULDBLOCK else { throw CocoaError(.fileWriteUnknown) }
            let text = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
            throw Held(pid: pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
        fd = opened
        let bytes = Array(String(pid).utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, bytes, bytes.count, 0)
    }

    /// Gives up the lock, if held.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
