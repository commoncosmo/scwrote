import Foundation
import Testing
@testable import ScwroteCore

/// Project search reads nvim's unsaved buffers and opens matches in it. These
/// run a real nvim; paths go through `realpath` (see `NvimFileSyncTests`).
@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
final class NvimSearchTests {
    let nvim: HeadlessNvim
    let client: NvimClient
    let folder: String

    init() throws {
        nvim = try HeadlessNvim()
        client = NvimClient(socketPath: nvim.socketPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote search \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        folder = realpath(temp.path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    @Test func listsModifiedBuffersUnderTheRootOnly() throws {
        let a = try file("root/a.txt", "one\n")
        let b = try file("root/b.txt", "two\n")
        let c = try file("other/c.txt", "three\n")
        try client.edit(a)
        try command("normal! ox")
        try client.edit(b)
        try client.edit(c)
        try command("normal! ox")

        #expect(try client.unsavedBuffers(under: path("root")) == [UnsavedBuffer(path: a, text: "one\nx\n")])
        #expect(try client.unsavedBuffers(under: path("root") + "/") == [UnsavedBuffer(path: a, text: "one\nx\n")])
    }

    @Test func textIsTheBuffersNotTheDisks() throws {
        let a = try file("root/a.txt", "one\n")
        try client.edit(a)
        _ = try lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two' })")
        _ = try lua("vim.bo.eol = false")

        #expect(try client.unsavedBuffers(under: path("root")) == [UnsavedBuffer(path: a, text: "one\ntwo")])
    }

    @Test func opensAtTheMatch() throws {
        let a = try file("a.txt", "1\n2\n3\n4\nfoo needle\n")

        try client.open(a, line: 5, column: 4, query: "needle")

        #expect(try client.currentFile() == a)
        #expect(try lua("return vim.api.nvim_win_get_cursor(0)") == .array([.int(5), .int(4)]))
    }

    @Test func openSetsALiteralSearchPattern() throws {
        let a = try file("a.txt", "x\na\\b/c.*\nab/cxx\nA\\B/C.*\n")

        try client.open(a, line: 2, column: 0, query: "a\\b/c.*")

        #expect(try lua("return vim.api.nvim_win_get_cursor(0)") == .array([.int(2), .int(0)]))
        #expect(try lua("return vim.fn.getreg('/')") == .string("\\V\\ca\\\\b\\/c.*"))
        try command("normal! n")
        #expect(try lua("return vim.api.nvim_win_get_cursor(0)[1]") == .int(4))
    }

    @Test func openKeepsTheCurrentBufferWhenAlreadyThere() throws {
        let a = try file("a.txt", "one\ntwo\n")
        try client.edit(a)
        try command("normal! ox")

        try client.open(a, line: 3, column: 1, query: "wo")

        #expect(try lua("return vim.bo.modified") == .bool(true))
        #expect(try lua("return vim.api.nvim_win_get_cursor(0)") == .array([.int(3), .int(1)]))
    }

    @Test func openGoesToTheLastLineWhenTheFileShrank() throws {
        let a = try file("a.txt", "one\ntwo\n")

        try client.open(a, line: 9, column: 0, query: "x")

        #expect(try lua("return vim.api.nvim_win_get_cursor(0)[1]") == .int(2))
    }

    // MARK: - Helpers

    private func path(_ relative: String) -> String {
        folder + "/" + relative
    }

    private func file(_ relative: String, _ text: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        return full
    }

    /// Only for fixed commands: paths never go in here.
    private func command(_ command: String) throws {
        _ = try client.request("nvim_command", [.string(command)])
    }

    private func lua(_ code: String) throws -> MessagePackValue {
        try client.request("nvim_exec_lua", [.string(code), .array([])])
    }
}
