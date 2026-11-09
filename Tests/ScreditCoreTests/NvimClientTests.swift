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

    @Test func notificationsFromNvimArrive() throws {
        let nvim = try HeadlessNvim()
        let listener = NvimClient(socketPath: nvim.socketPath)
        let channel = try listener.channelID()

        _ = try NvimClient(socketPath: nvim.socketPath).request("nvim_exec_lua", [
            .string("vim.rpcnotify(..., 'hello', 1)"), .array([.int(channel)]),
        ])

        #expect(try listener.nextNotification(timeout: 5) == NvimNotification(method: "hello", params: [.int(1)]))
    }

    /// A notification can arrive while the client waits for an answer; it's
    /// kept for later, not dropped.
    @Test func aNotificationDuringARequestIsKept() throws {
        let nvim = try HeadlessNvim()
        let listener = NvimClient(socketPath: nvim.socketPath)
        let channel = try listener.channelID()

        let answer = try listener.request("nvim_exec_lua", [
            .string("vim.rpcnotify(..., 'early'); return 7"), .array([.int(channel)]),
        ])

        #expect(answer == .int(7))
        #expect(try listener.nextNotification(timeout: 5) == NvimNotification(method: "early", params: []))
    }

    @Test func connectingToASocketThatNeverAppearsGivesUp() {
        let client = NvimClient(socketPath: NSTemporaryDirectory() + "sn-missing.sock", connectTimeout: 0.2)

        #expect(throws: NvimClient.Failure.self) {
            try client.currentFile()
        }
    }
}

/// A headless nvim with scredit's Ctrl-w mappings, and a way to press keys in it.
private struct MappedNvim {
    let nvim: HeadlessNvim
    let listener: NvimClient
    let control: NvimClient
    let channel: Int64

    /// `userConfig` runs first, as the user's own config would.
    init(userConfig: String? = nil) throws {
        nvim = try HeadlessNvim()
        listener = NvimClient(socketPath: nvim.socketPath)
        control = NvimClient(socketPath: nvim.socketPath)
        if let userConfig { _ = try control.request("nvim_exec_lua", [.string(userConfig), .array([])]) }
        try listener.installPaneMappings()
        channel = try listener.channelID()
    }

    @discardableResult
    func lua(_ code: String) throws -> MessagePackValue {
        try control.request("nvim_exec_lua", [.string(code), .array([])])
    }

    /// Types keys in normal mode, mappings included, and returns once they ran.
    func press(_ keys: String) throws {
        _ = try control.request("nvim_exec_lua", [
            .string("vim.api.nvim_feedkeys(vim.keycode(...), 'mx', false)"), .array([.string(keys)]),
        ])
    }

    /// Whether nvim asked scredit for the browser: a marker sent after the
    /// keys arrives first if it didn't.
    func askedForBrowser() throws -> Bool {
        try lua("vim.rpcnotify(\(channel), 'marker')")
        return try listener.nextNotification(timeout: 5) == NvimPaneMappings.browserRequest
    }

    func window() throws -> MessagePackValue {
        try lua("return vim.fn.winnr()")
    }
}

@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
struct NvimPaneMappingsTests {
    /// With one nvim window, every one of these is "off the edge".
    @Test(arguments: ["<C-w>h", "<C-w><C-h>", "<C-w>w", "<C-w><C-w>", "<C-w>W"])
    func ctrlWPastTheEdgeAsksForTheBrowser(keys: String) throws {
        let nvim = try MappedNvim()

        try nvim.press(keys)

        #expect(try nvim.askedForBrowser())
    }

    @Test func ctrlWHMovesToASplitOnTheLeftFirst() throws {
        let nvim = try MappedNvim()
        try nvim.lua("vim.cmd.vsplit(); vim.cmd.wincmd('l')")
        #expect(try nvim.window() == .int(2))

        try nvim.press("<C-w>h")

        #expect(try nvim.window() == .int(1))
        #expect(try !nvim.askedForBrowser())
    }

    @Test func ctrlWWCyclesThroughSplitsBeforeTheBrowser() throws {
        let nvim = try MappedNvim()
        try nvim.lua("vim.cmd.vsplit()")
        #expect(try nvim.window() == .int(1))

        try nvim.press("<C-w>w")
        #expect(try nvim.window() == .int(2))
        #expect(try !nvim.askedForBrowser())

        try nvim.press("<C-w>w")
        #expect(try nvim.askedForBrowser())
    }

    @Test func ctrlWCapitalWFromALaterSplitGoesBackFirst() throws {
        let nvim = try MappedNvim()
        try nvim.lua("vim.cmd.vsplit(); vim.cmd.wincmd('l')")

        try nvim.press("<C-w>W")

        #expect(try nvim.window() == .int(1))
        #expect(try !nvim.askedForBrowser())
    }

    /// `2 Ctrl-w w` means "window 2" in vim; with a count it's plain vim.
    @Test func aCountKeepsVimsOwnMeaning() throws {
        let nvim = try MappedNvim()
        try nvim.lua("vim.cmd.vsplit()")

        try nvim.press("2<C-w>w")

        #expect(try nvim.window() == .int(2))
        #expect(try !nvim.askedForBrowser())
    }

    @Test func theUsersOwnMappingWins() throws {
        let nvim = try MappedNvim(userConfig: "vim.keymap.set('n', '<C-w>h', function() vim.g.mine = 1 end)")

        try nvim.press("<C-w>h")

        #expect(try nvim.lua("return vim.g.mine") == .int(1))
        #expect(try !nvim.askedForBrowser())
    }
}
