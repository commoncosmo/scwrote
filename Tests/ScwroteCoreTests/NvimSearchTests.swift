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

    @Test func nAfterOpenGoesForwardEvenAfterABackwardSearch() throws {
        let a = try file("a.txt", "needle\nx\nneedle\nx\nneedle\n")
        try client.edit(a)
        try command("execute \"normal! G?needle\\<CR>\"")
        #expect(try lua("return vim.v.searchforward") == .int(0))

        try client.open(a, line: 3, column: 0, query: "needle")

        try command("normal! n")
        #expect(try lua("return vim.api.nvim_win_get_cursor(0)[1]") == .int(5))
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

    // MARK: - Quickfix

    @Test func entriesCarryFileLineColumnAndText() throws {
        let a = try file("a.txt", "x\n  foo needle\n")
        let b = try file("b.txt", "needle one\nneedle two\n")
        try client.sendToQuickfix([
            match(a, 2, 6, "  foo needle"), match(b, 1, 0, "needle one"), match(b, 2, 0, "needle two"),
        ], query: "needle")

        let items = try lua("""
            local out = {}
            for _, item in ipairs(vim.fn.getqflist()) do
              table.insert(out, { vim.api.nvim_buf_get_name(item.bufnr), item.lnum, item.col, item.text })
            end
            return out
            """)
        #expect(items == .array([
            .array([.string(a), .int(2), .int(7), .string("  foo needle")]),
            .array([.string(b), .int(1), .int(1), .string("needle one")]),
            .array([.string(b), .int(2), .int(1), .string("needle two")]),
        ]))
    }

    @Test func theListIsNewAndTitled() throws {
        let a = try file("a.txt", "needle\n")
        _ = try lua("vim.fn.setqflist({}, ' ', { title = 'mine' })")
        try client.sendToQuickfix([match(a, 1, 0, "needle")], query: "needle")

        #expect(try lua("return vim.fn.getqflist({ nr = '$' }).nr") == .int(2))
        #expect(try lua("return vim.fn.getqflist({ title = 0 }).title") == .string("scwrote search \"needle\""))
        #expect(try lua("return vim.fn.getqflist({ nr = 1, title = 0 }).title") == .string("mine"))
    }

    @Test func cursorLandsOnTheFirstMatchOutsideTheQuickfixWindow() throws {
        let a = try file("a.txt", (1...100).map { $0 == 40 ? "the needle" : "line \($0)" }.joined(separator: "\n") + "\n")
        try client.sendToQuickfix([match(a, 40, 4, "the needle")], query: "needle")

        #expect(try lua("""
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'quickfix' then return true end
            end
            return false
            """) == .bool(true))
        #expect(try lua("return vim.bo.buftype") == .string(""))
        #expect(try client.currentFile() == a)
        #expect(try lua("return vim.api.nvim_win_get_cursor(0)") == .array([.int(40), .int(4)]))
        #expect(try lua("return vim.fn.winline() == math.floor((vim.fn.winheight(0) + 1) / 2)") == .bool(true))
    }

    @Test func searchStateIsSetLikeOpening() throws {
        let a = try file("a.txt", "needle\n")
        _ = try lua("vim.v.searchforward = 0")
        try client.sendToQuickfix([match(a, 1, 0, "needle")], query: "needle")

        #expect(try lua("return vim.fn.getreg('/')") == .string("\\V\\cneedle"))
        #expect(try lua("return vim.v.searchforward") == .int(1))
    }

    @Test func specialCharactersInTheQueryStayLiteral() throws {
        let query = "a\"b|c%d\\e/f"
        let a = try file("a.txt", query + "\n")
        try client.sendToQuickfix([match(a, 1, 0, query)], query: query)

        #expect(try lua("return vim.fn.getqflist({ title = 0 }).title") == .string("scwrote search \"\(query)\""))
        #expect(try lua("return vim.fn.getreg('/')") == .string("\\V\\ca\"b|c%d\\\\e\\/f"))
    }

    @Test func aLargeListArrivesWhole() throws {
        let a = try file("a.txt", String(repeating: "needle\n", count: 5000))
        try client.sendToQuickfix((1...5000).map { match(a, $0, 0, "needle") }, query: "needle")

        #expect(try lua("return #vim.fn.getqflist()") == .int(5000))
    }

    @Test func entriesForOddFileNamesOpenThem() throws {
        let odd = try file("dir with space/a #b [c] %d.txt", "needle\n")
        try client.sendToQuickfix([match(odd, 1, 0, "needle")], query: "needle")

        #expect(try client.currentFile() == odd)
    }

    /// nvim can take longer than a call's read timeout to build a list over
    /// thousands of files; sending waits it out instead of failing.
    @Test func aSlowHandoverIsWaitedOut() throws {
        let a = try file("a.txt", "needle\n")
        try command("autocmd BufEnter * lua vim.wait(500)")
        let impatient = NvimClient(socketPath: nvim.socketPath, queuesNotifications: false, readTimeout: 0.1)

        try impatient.sendToQuickfix([match(a, 1, 0, "needle")], query: "needle")

        #expect(try client.currentFile() == a)
    }

    @Test func noMatchesChangesNothing() throws {
        try client.sendToQuickfix([], query: "needle")

        #expect(try lua("return vim.fn.getqflist({ nr = '$' }).nr") == .int(0))
        #expect(try lua("return #vim.api.nvim_list_wins()") == .int(1))
    }

    // MARK: - Helpers

    /// A match whose overlay text differs from its whole line, as a long
    /// line's does, so the tests show which one reaches quickfix.
    private func match(_ path: String, _ line: Int, _ column: Int, _ lineText: String) -> SearchMatch {
        SearchMatch(path: path, line: line, column: column, text: "…trimmed for the overlay…", ranges: [],
                    lineText: lineText)
    }

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
