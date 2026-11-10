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

    @Test func connectingToASocketThatNeverAppearsGivesUp() {
        let client = NvimClient(socketPath: NSTemporaryDirectory() + "sn-missing.sock", connectTimeout: 0.2)

        #expect(throws: NvimClient.Failure.self) {
            try client.currentFile()
        }
    }
}
