import Foundation
import Testing
@testable import ScwroteCore

/// The browser moves and trashes files on disk, then tells nvim. These run a
/// real nvim. Paths go through `realpath`: the temp folder /var/... is a
/// symlink to /private/var/..., and nvim names buffers by the real path. The
/// folder name has a space, so paths only ever reach nvim as Lua arguments.
@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
final class NvimFileSyncTests {
    let nvim: HeadlessNvim
    let client: NvimClient
    let folder: String

    init() throws {
        nvim = try HeadlessNvim()
        client = NvimClient(socketPath: nvim.socketPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote sync \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        folder = realpath(temp.path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    @Test func renamingAnOpenFileKeepsItsChanges() throws {
        let a = try file("a.md", "one\n")
        try client.edit(a)
        try command("normal! ox")
        let b = path("b.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)

        #expect(try client.currentFile() == b)
        #expect(try isModified())
        // Not written by the rename: the file still has what was saved.
        #expect(try contents(b) == "one\n")
        _ = try client.request("nvim_exec2", [.string("write"), .map([:])])
        #expect(try contents(b) == "one\nx\n")
        #expect(try !bufferNames().contains(a))
    }

    @Test func undoHistorySurvivesTheRename() throws {
        let a = try file("a.md", "one\n")
        try client.edit(a)
        try command("normal! ox")
        let b = path("b.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)
        try command("undo")

        #expect(try lines() == ["one"])
        // Back at what's on disk, so nothing is unsaved.
        #expect(try !isModified())
    }

    @Test func renamingKeepsTheAlternateFile() throws {
        let other = try file("other.md", "")
        let a = try file("a.md", "")
        try client.edit(other)
        try client.edit(a)
        let b = path("b.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)

        #expect(try lua("return vim.api.nvim_buf_get_name(vim.fn.bufnr('#'))") == .string(other))
    }

    @Test func renamingAFolderRenamesTheFilesInside() throws {
        try command("set hidden")
        let hidden = try file("d/hidden.md", "h\n")
        let shown = try file("d/sub/shown.md", "s\n")
        try client.edit(hidden)
        try command("normal! ox")
        try client.edit(shown)
        try FileManager.default.moveItem(atPath: path("d"), toPath: path("e"))

        try client.renameBuffers(from: path("d"), to: path("e"))

        let names = try bufferNames()
        #expect(names.contains(path("e/hidden.md")))
        #expect(names.contains(path("e/sub/shown.md")))
        #expect(!names.contains { $0.hasPrefix(path("d") + "/") })
        // The hidden buffer can be written under its new name too.
        let number = try bufferNumber(path("e/hidden.md"))
        try command("buffer \(number)")
        try command("write")
        #expect(try contents(path("e/hidden.md")) == "h\nx\n")
    }

    @Test func unrelatedBuffersAreLeftAlone() throws {
        try command("set hidden")
        let inside = try file("d/a.md", "")
        let neighbour = try file("d2/x.md", "")
        try client.edit(neighbour)
        try client.edit(inside)
        try FileManager.default.moveItem(atPath: path("d"), toPath: path("e"))

        try client.renameBuffers(from: path("d"), to: path("e"))

        #expect(try bufferNames().contains(neighbour))
    }

    @Test func aBufferThatIsNotLoadedIsDropped() throws {
        try command("set hidden")
        let a = try file("a.md", "")
        let other = try file("other.md", "")
        try client.edit(a)
        try client.edit(other)
        try command("bunload \(try bufferNumber(a))")
        let b = path("b.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)

        #expect(try !bufferNames().contains(a))
    }

    @Test func renamingOnlyTheCaseOfAFile() throws {
        let a = try file("notes.md", "one\n")
        try client.edit(a)
        try command("normal! ox")
        let b = path("Notes.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)

        #expect(try client.currentFile() == b)
        #expect(try isModified())
        try command("write")
        #expect(try contents(b) == "one\nx\n")
        #expect(try !bufferNames().contains(a))
    }

    /// A BufWriteCmd of the user's that matches the new name would write for
    /// real if the rename's empty write ran, so the empty write is skipped.
    @Test func aWriteHandlerForTheFileIsNeverRun() throws {
        _ = try lua("""
            vim.api.nvim_create_autocmd("BufWriteCmd", { pattern = "*.md", callback = function(ev)
              vim.fn.writefile(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), ev.match)
              vim.bo[ev.buf].modified = false
            end })
            """)
        let a = try file("a.md", "one\n")
        try client.edit(a)
        try command("normal! ox")
        let b = path("b.md")
        try FileManager.default.moveItem(atPath: a, toPath: b)

        try client.renameBuffers(from: a, to: b)

        #expect(try client.currentFile() == b)
        #expect(try isModified())
        #expect(try contents(b) == "one\n")
        #expect(try !bufferNames().contains(a))
        // The fallback: still "not edited", so a plain :w asks for :w!.
        #expect(throws: NvimClient.Failure.self) { try command("write") }
        #expect(try contents(b) == "one\n")
    }

    @Test(arguments: [
        ("*.md", true),
        ("*", true),
        ("*.MD", true),
        ("/private/*/b.md", true),
        ("*.{gpg,asc,pgp}", false),
        ("*.shada", false),
        ("zipfile:*", false),
        ("scp://*", false),
        ("*/elsewhere/*.md", false),
    ])
    func autocommandPatternsThatCouldMatchTheFile(pattern: String, matches: Bool) throws {
        let code = NvimClient.autocommandPatternLua + "\nreturn pattern_matches(...)"

        #expect(try lua(code, [.string(pattern), .string(path("notes/b.md"))]) == .bool(matches))
    }

    @Test func aBufferWithASpecialBuftypeIsRenamedWithTheRest() throws {
        try command("set hidden")
        let first = try file("d/a.md", "")
        try client.edit(first)
        _ = try lua("""
            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_name(buf, ...)
            """, [.string(path("d/m.md"))])
        let last = try file("d/z.md", "")
        try client.edit(last)
        try FileManager.default.moveItem(atPath: path("d"), toPath: path("e"))

        try client.renameBuffers(from: path("d"), to: path("e"))

        let names = try bufferNames()
        #expect(names.contains(path("e/a.md")))
        #expect(names.contains(path("e/m.md")))
        #expect(names.contains(path("e/z.md")))
        #expect(!names.contains { $0.hasPrefix(path("d") + "/") })
    }

    /// A loaded buffer already has one of the new names, so that rename
    /// fails; the others still happen, and the failure is reported.
    @Test func oneFailureDoesNotStopTheRest() throws {
        try command("set hidden")
        let a = try file("d/a.md", "")
        let b = try file("d/b.md", "")
        try client.edit(a)
        try client.edit(b)
        // A new, unwritten file: a buffer for e/a.md with nothing on disk.
        try client.edit(path("e/a.md"))
        try FileManager.default.moveItem(atPath: path("d"), toPath: path("e"))

        #expect(throws: NvimClient.Failure.self) {
            try client.renameBuffers(from: path("d"), to: path("e"))
        }

        let names = try bufferNames()
        #expect(names.contains(path("e/b.md")))
        #expect(!names.contains(b))
    }

    @Test func closingAFileDiscardsItsBuffer() throws {
        let a = try file("a.md", "one\n")
        try client.edit(a)
        try command("normal! ox")

        try client.closeBuffers(at: a)

        #expect(try !bufferNames().contains(a))
        #expect(try contents(a) == "one\n")
    }

    @Test func closingAFolderClosesTheBuffersInside() throws {
        try command("set hidden")
        let one = try file("d/one.md", "")
        let two = try file("d/sub/two.md", "")
        let neighbour = try file("d2/x.md", "")
        try client.edit(neighbour)
        try client.edit(one)
        try command("normal! ox")
        try client.edit(two)

        try client.closeBuffers(at: path("d"))

        let names = try bufferNames()
        #expect(!names.contains(one))
        #expect(!names.contains(two))
        #expect(names.contains(neighbour))
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

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Only for fixed commands: paths never go in here.
    private func command(_ command: String) throws {
        _ = try client.request("nvim_command", [.string(command)])
    }

    private func lua(_ code: String, _ arguments: [MessagePackValue] = []) throws -> MessagePackValue {
        try client.request("nvim_exec_lua", [.string(code), .array(arguments)])
    }

    private func bufferNames() throws -> [String] {
        guard case let .array(names) = try lua("return vim.tbl_map(vim.api.nvim_buf_get_name, vim.api.nvim_list_bufs())")
        else { return [] }
        return names.compactMap { if case let .string(name) = $0 { name } else { nil } }
    }

    private func bufferNumber(_ name: String) throws -> Int64 {
        let code = """
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_get_name(buf) == ... then return buf end
            end
            return -1
            """
        guard case let .int(number) = try lua(code, [.string(name)]) else { return -1 }
        return number
    }

    private func isModified() throws -> Bool {
        try lua("return vim.bo.modified") == .bool(true)
    }

    private func lines() throws -> [String] {
        guard case let .array(lines) = try lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)") else { return [] }
        return lines.compactMap { if case let .string(line) = $0 { line } else { nil } }
    }
}
