import Foundation
import Testing
@testable import ScwroteCore

@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
struct NvimClientTests {
    @Test func editOpensTheFileInNvim() throws {
        let nvim = try HeadlessNvim()
        let client = NvimClient(socketPath: nvim.socketPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote nvim \(UUID().uuidString)")
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

    /// nvim sends `rpcnotify(0, ...)` to every channel. The app's own client
    /// never asks for notifications, so it must not keep them.
    @Test func notificationsAreDroppedUnlessQueued() throws {
        let nvim = try HeadlessNvim()
        let client = NvimClient(socketPath: nvim.socketPath)
        let listening = NvimClient(socketPath: nvim.socketPath, queuesNotifications: true)
        _ = try listening.channelID()

        _ = try client.request("nvim_exec_lua", [.string("vim.rpcnotify(0, 'broadcast', 1)"), .array([])])
        // Sent after the notification, so answered after it arrives.
        _ = try client.channelID()
        _ = try listening.channelID()

        #expect(client.queuedNotificationCount == 0)
        #expect(listening.queuedNotificationCount == 1)
    }

    @Test func connectingToASocketThatNeverAppearsGivesUp() {
        let client = NvimClient(socketPath: NSTemporaryDirectory() + "sn-missing.sock", connectTimeout: 0.2)

        #expect(throws: NvimClient.Failure.self) {
            try client.currentFile()
        }
    }
}
