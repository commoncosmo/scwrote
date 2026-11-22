import Foundation

public enum Ripgrep {
    /// Arguments for a literal, case-insensitive search that prints JSON.
    /// `--no-require-git` makes `.gitignore` count even outside a repository.
    /// With `stdin`, searches standard input instead of the directory.
    public static func searchArguments(_ query: String, stdin: Bool) -> [String] {
        ["--json", "--no-config", "--no-require-git", "--fixed-strings", "--ignore-case", "--", query]
            + (stdin ? ["-"] : [])
    }

    public static let fileListArguments = ["--files", "--no-config", "--no-require-git"]

    /// The bundled `rg` beside the app binary, else `.build/ripgrep/rg` in the
    /// nearest ancestor folder named `.build`, else `rg` on `searchPath`.
    public static func locate(executableDirectory: String, searchPath: String) -> String? {
        let fileManager = FileManager.default
        let bundled = executableDirectory + "/rg"
        if fileManager.isExecutableFile(atPath: bundled) { return bundled }

        var folder = URL(fileURLWithPath: executableDirectory)
        while folder.path != "/" {
            if folder.lastPathComponent == ".build" {
                let fetched = folder.appendingPathComponent("ripgrep/rg").path
                if fileManager.isExecutableFile(atPath: fetched) { return fetched }
                break
            }
            folder = folder.deletingLastPathComponent()
        }
        return ExecutableLocator.find("rg", searchPath: searchPath)
    }
}

/// One ripgrep process. Calls `onLine` with each stdout line (no newline) on a
/// background thread, then `onExit` once. After `cancel()`, neither is called:
/// callbacks run under a lock that `cancel()` takes, so `cancel()` waits for a
/// callback already running (don't block a callback on the thread that calls
/// `cancel()`). Calling `cancel()` from within a callback is fine.
///
/// Spawned with `posix_spawn` rather than `Process`, which rewrites argument
/// strings to decomposed Unicode (NFD) and so breaks queries like "école".
public final class RipgrepRun: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var reaped = false

    public init(executable: String, arguments: [String], directory: String, stdin: Data?,
                onLine: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable () -> Void) throws {
        // Writing to a ripgrep that already exited must fail, not kill us.
        signal(SIGPIPE, SIG_IGN)

        var outPipe: [Int32] = [0, 0]
        var inPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if stdin != nil, pipe(&inPipe) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(code)
        }

        // Close-on-exec everywhere, so no other child process we start can
        // inherit these ends (a leaked stdin write end would keep a ripgrep
        // from ever seeing EOF).
        for fd in outPipe + (stdin != nil ? inPipe : []) {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // ripgrep gets only 0, 1 and 2, not the app's ptys and sockets.
        // and default signal handling, whatever this thread blocks or ignores
        // (we ignore SIGPIPE below; cancel() relies on SIGTERM working).
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Never the parent's stdin: with a non-tty stdin ripgrep would search it.
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, directory)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        close(outPipe[1])
        if stdin != nil { close(inPipe[0]) }
        guard status == 0 else {
            close(outPipe[0])
            if stdin != nil { close(inPipe[1]) }
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        pid = child

        if let stdin {
            let writer = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
            Thread.detachNewThread {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        let reader = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending = Data(pending[(newline + 1)...])
                    if !emit({ onLine(line) }) { return finish() }
                }
            }
            if !pending.isEmpty, !emit({ onLine(pending) }) { return finish() }
            finish(then: onExit)
        }
    }

    /// Runs `callback` unless cancelled; false once cancelled.
    private func emit(_ callback: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        callback()
        return true
    }

    /// Waits for the process, reaps it, and then calls `exit` unless cancelled.
    private func finish(then exit: (() -> Void)? = nil) {
        var info = siginfo_t()
        // Wait without reaping, so cancel() can't signal a recycled pid.
        waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        lock.lock()
        defer { lock.unlock() }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        reaped = true
        if !cancelled { exit?() }
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if !reaped { kill(pid, SIGTERM) }
    }
}
