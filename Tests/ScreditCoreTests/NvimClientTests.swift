import Foundation
import Testing
@testable import ScreditCore

private let nvimPath = ExecutableLocator.find("nvim", searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")

/// A real headless nvim listening on a fresh socket, stopped when the test ends.
private final class HeadlessNvim {
    let socketPath: String
    private let process = Process()

    init() throws {
        // Unix socket paths are limited to ~104 bytes, so keep this short.
        socketPath = NSTemporaryDirectory() + "sn-\(UUID().uuidString.prefix(8)).sock"
        process.executableURL = URL(fileURLWithPath: nvimPath!)
        process.arguments = ["--headless", "--clean", "--listen", socketPath]
        try process.run()
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

private func realpath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
struct NvimClientTests {
    @Test func editOpensTheFileInNvim() throws {
        let nvim = try HeadlessNvim()
        let client = NvimClient(socketPath: nvim.socketPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scredit nvim \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("it's my notes.md").path
        FileManager.default.createFile(atPath: file, contents: Data("# hi\n".utf8))

        try client.edit(file)

        // nvim reports the real path: the temp folder /var/... is a symlink
        // to /private/var/...
        #expect(try client.currentFile() == realpath(file))
    }

    @Test func currentFileIsNilForAnUnnamedBuffer() throws {
        let nvim = try HeadlessNvim()
        let client = NvimClient(socketPath: nvim.socketPath)

        #expect(try client.currentFile() == nil)
    }

    @Test func errorsFromNvimAreReported() throws {
        let nvim = try HeadlessNvim()
        let client = NvimClient(socketPath: nvim.socketPath)

        #expect(throws: NvimClient.Failure.self) {
            try client.request("nvim_no_such_function", [])
        }
    }

    @Test func connectingToASocketThatNeverAppearsGivesUp() {
        let client = NvimClient(socketPath: NSTemporaryDirectory() + "sn-missing.sock", connectTimeout: 0.2)

        #expect(throws: NvimClient.Failure.self) {
            try client.currentFile()
        }
    }
}
