import Foundation
@testable import ScwroteCore

let nvimPath = ExecutableLocator.find("nvim", searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")

/// A real headless nvim listening on a fresh socket, stopped when the test ends.
final class HeadlessNvim {
    let socketPath: String
    private let process = Process()

    /// `arguments` follow the ones that make it headless and listening.
    init(arguments: [String] = []) throws {
        // Unix socket paths are limited to ~104 bytes, so keep this short.
        socketPath = NSTemporaryDirectory() + "sn-\(UUID().uuidString.prefix(8)).sock"
        process.executableURL = URL(fileURLWithPath: nvimPath!)
        // -n: no swap files, which nvim would otherwise leave behind for
        // modified buffers when it's terminated.
        process.arguments = ["--headless", "--clean", "-n", "--listen", socketPath] + arguments
        // Keep its screen output out of the test log.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

func realpath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
