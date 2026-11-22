import Foundation
@testable import ScwroteCore

/// The pinned ripgrep from scripts/fetch-ripgrep.sh if it was fetched, else
/// whatever `rg` is on PATH.
let rgPath: String? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pinned = root.appendingPathComponent(".build/ripgrep/rg").path
    if FileManager.default.isExecutableFile(atPath: pinned) { return pinned }
    return ExecutableLocator.find("rg", searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
}()

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    func add(_ line: Data) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [Data] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Runs ripgrep with `args` in `dir` and returns every stdout line once it exits.
func runCollecting(_ args: [String], in dir: String, stdin: Data? = nil) throws -> [Data] {
    let collector = Collector()
    let done = DispatchSemaphore(value: 0)
    let run = try RipgrepRun(
        executable: rgPath!, arguments: args, directory: dir, stdin: stdin,
        onLine: { collector.add($0) },
        onExit: { done.signal() })
    done.wait()
    _ = run
    return collector.all
}
