import Foundation
import Testing
@testable import ScwroteCore

/// nvim's side of reopening a folder: a narrow `:mksession` written on exit or
/// on request, and loaded back into a fresh nvim. These run real nvims (one
/// saves, a fresh one restores); paths go through `realpath` (see
/// `NvimFileSyncTests`).
@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
final class NvimSessionTests {
    let nvim: HeadlessNvim
    let client: NvimClient
    let folder: String
    let sessionPath: String

    init() throws {
        nvim = try HeadlessNvim()
        client = NvimClient(socketPath: nvim.socketPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote session \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        folder = realpath(temp.path)
        sessionPath = folder + "/state/session.vim"
        try FileManager.default.createDirectory(atPath: folder + "/state", withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    @Test func savesFilesSplitsAndCursors() throws {
        let a = try file("a.txt", numbered(20))
        let b = try file("b.txt", numbered(20))
        let c = try file("c.txt", numbered(20))
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        _ = try lua(client, "vim.api.nvim_win_set_cursor(0, { 7, 2 })")
        try command(client, "tabnew " + escaped(c))
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim()
        #expect(try other.restoreSession(from: sessionPath, namedFiles: []) == .restored)

        #expect(try lua(other, "return #vim.api.nvim_list_tabpages()") == .int(2))
        let firstTab = try lua(other, """
            local tab = vim.api.nvim_list_tabpages()[1]
            local names = {}
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              table.insert(names, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
            end
            table.sort(names)
            return names
            """)
        #expect(firstTab == .array([.string(a), .string(b)]))
        let cursor = try lua(other, """
            local tab = vim.api.nvim_list_tabpages()[1]
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == ... then
                return vim.api.nvim_win_get_cursor(win)
              end
            end
            """, [.string(b)])
        #expect(cursor == .array([.int(7), .int(2)]))
        withExtendedLifetime(fresh) {}
    }

    @Test func savingWritesNoUserOptions() throws {
        let a = try file("a.txt", "a\n")
        try client.edit(a)
        try command(client, "set winwidth=33 tabstop=3 sessionoptions=blank,help")

        try client.saveSession(to: sessionPath)

        let text = try String(contentsOfFile: sessionPath, encoding: .utf8)
        #expect(!text.contains("tabstop"))
        #expect(!text.contains("ts="))
        #expect(try lua(client, "return vim.o.sessionoptions") == .string("blank,help"))
    }

    @Test func aFailedSaveStillPutsTheSessionOptionsBack() throws {
        let a = try file("a.txt", "a\n")
        try client.edit(a)
        try command(client, "set sessionoptions=blank,help")

        #expect(throws: NvimClient.Failure.self) {
            try self.client.saveSession(to: self.folder + "/no such folder/session.vim")
        }

        #expect(try lua(client, "return vim.o.sessionoptions") == .string("blank,help"))
    }

    @Test func theUsersOptionsWinOverTheSession() throws {
        let a = try file("a.txt", numbered(5))
        let b = try file("b.txt", numbered(5))
        try client.edit(a)
        try command(client, "tabnew " + escaped(b))
        try command(client, "set winwidth=33 winheight=1 showtabline=2 hlsearch scrolloff=5 sidescrolloff=4 shortmess+=I")
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim()
        try command(other, "set winwidth=20 winheight=4 winminheight=3 showtabline=0 nohlsearch scrolloff=2")
        try command(other, "set sidescrolloff=1 splitbelow splitright shortmess=at")

        #expect(try other.restoreSession(from: sessionPath, namedFiles: []) == .restored)

        #expect(try lua(other, "return vim.o.winwidth") == .int(20))
        #expect(try lua(other, "return vim.o.winheight") == .int(4))
        #expect(try lua(other, "return vim.o.winminheight") == .int(3))
        #expect(try lua(other, "return vim.o.showtabline") == .int(0))
        #expect(try lua(other, "return vim.o.hlsearch") == .bool(false))
        #expect(try lua(other, "return vim.go.scrolloff") == .int(2))
        #expect(try lua(other, "return vim.go.sidescrolloff") == .int(1))
        #expect(try lua(other, "return vim.o.splitbelow and vim.o.splitright") == .bool(true))
        #expect(try lua(other, "return vim.o.shortmess") == .string("at"))
        withExtendedLifetime(fresh) {}
    }

    @Test func nothingToSaveDeletesTheOldSession() throws {
        try Data("\" old\n".utf8).write(to: URL(fileURLWithPath: sessionPath))

        try client.saveSession(to: sessionPath)

        #expect(!FileManager.default.fileExists(atPath: sessionPath))
        try client.saveSession(to: sessionPath)
    }

    @Test func vimLeavePreSaves() throws {
        let a = try file("a.txt", "a\n")
        try client.installSessionSaver(path: sessionPath)
        try client.edit(a)

        // nvim may exit before it answers.
        _ = try? client.request("nvim_command", [.string("qa!")])

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: sessionPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let (fresh, other) = try freshNvim()
        #expect(try other.restoreSession(from: sessionPath, namedFiles: []) == .restored)
        #expect(try listedFiles(other) == [a])
        withExtendedLifetime(fresh) {}
    }

    @Test func missingSessionIsReported() throws {
        #expect(try client.restoreSession(from: folder + "/none.vim", namedFiles: []) == .missing)
    }

    @Test func skipsWhenASessionIsAlreadyLoaded() throws {
        let a = try file("a.txt", "a\n")
        let b = try file("b.txt", "b\n")
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        try client.saveSession(to: sessionPath)
        try command(client, "only")
        _ = try lua(client, "vim.v.this_session = '/x'")

        #expect(try client.restoreSession(from: sessionPath, namedFiles: []) == .skipped)

        #expect(try lua(client, "return #vim.api.nvim_list_wins()") == .int(1))
        #expect(try lua(client, "return vim.v.this_session") == .string("/x"))
    }

    @Test func skipsWhenASessionIsAlreadyLoadedEvenWithoutAFile() throws {
        _ = try lua(client, "vim.v.this_session = '/x'")

        #expect(try client.restoreSession(from: folder + "/none.vim", namedFiles: []) == .skipped)
    }

    @Test func aBrokenSessionLeavesNvimUsable() throws {
        try Data("edit /nope\nthis is not vimscript".utf8).write(to: URL(fileURLWithPath: sessionPath))

        let result = try client.restoreSession(from: sessionPath, namedFiles: [])

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
        try command(client, "enew")
        _ = try lua(client, "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'still works' })")
        #expect(try lua(client, "return vim.api.nvim_get_current_line()") == .string("still works"))
        #expect(try lua(client, "return vim.fn.bufexists('/nope')") == .int(0))
        #expect(try lua(client, "return vim.v.this_session") == .string(""))
        #expect(try lua(client, "return vim.g.SessionLoad") == .nil)
    }

    @Test func aNoisyAutocommandDoesntCostTheLayout() throws {
        let a = try file("a.txt", "a\n")
        let b = try file("b.txt", "b\n")
        let c = try file("c.txt", "c\n")
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        try command(client, "tabnew " + escaped(c))
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim()
        try command(other, "autocmd BufReadPost */b.txt echoerr 'plugin oops'")
        let result = try other.restoreSession(from: sessionPath, namedFiles: [])

        guard case let .failed(message) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(message.contains("plugin oops"))
        #expect(try lua(other, "return #vim.api.nvim_list_tabpages()") == .int(2))
        #expect(try lua(other, "return #vim.api.nvim_list_wins()") == .int(3))
        #expect(Set(try listedFiles(other)) == [a, b, c])
        #expect(try lua(other, "return vim.v.this_session") == .string(""))
        #expect(try lua(other, "return vim.g.SessionLoad") == .nil)
        withExtendedLifetime(fresh) {}
    }

    @Test func savingLeavesThisSessionAlone() throws {
        let a = try file("a.txt", "a\n")
        try client.edit(a)

        try client.saveSession(to: sessionPath)
        #expect(try lua(client, "return vim.v.this_session") == .string(""))

        _ = try lua(client, "vim.v.this_session = '/the users session.vim'")
        try client.saveSession(to: sessionPath)
        #expect(try lua(client, "return vim.v.this_session") == .string("/the users session.vim"))

        let failing = folder + "/no such folder/session.vim"
        #expect(throws: NvimClient.Failure.self) { try self.client.saveSession(to: failing) }
        #expect(try lua(client, "return vim.v.this_session") == .string("/the users session.vim"))
    }

    @Test func aRestoredSessionLeavesThisSessionEmpty() throws {
        let a = try file("a.txt", "a\n")
        try client.edit(a)
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim()
        #expect(try other.restoreSession(from: sessionPath, namedFiles: []) == .restored)

        #expect(try lua(other, "return vim.v.this_session") == .string(""))
        withExtendedLifetime(fresh) {}
    }

    @Test func theNamedFilesAreTheArgumentList() throws {
        let a = try file("a.txt", "a\n")
        let c = try file("c.txt", "c\n")
        let d = try file("d.txt", "d\n")
        try client.edit(a)
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim(arguments: [c, d])
        #expect(try other.restoreSession(from: sessionPath, namedFiles: [folder + "/echo", c, d]) == .restored)

        #expect(try lua(other, "return vim.fn.argv()") == .array([.string(c), .string(d)]))
        #expect(try other.currentFile() == c)
        withExtendedLifetime(fresh) {}
    }

    @Test func aBrokenSessionStillPutsTheOptionsBackAndShowsTheNamedFile() throws {
        let named = try file("named.txt", "n\n")
        try client.edit(named)
        try command(client, "set showtabline=0 winheight=3 nohlsearch")
        let script = """
            let v:this_session = '/broken'
            set showtabline=2 winminheight=0 winheight=1 hlsearch
            edit /nope
            this is not vimscript
            """
        try Data(script.utf8).write(to: URL(fileURLWithPath: sessionPath))

        let result = try client.restoreSession(from: sessionPath, namedFiles: [named])

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(try lua(client, "return vim.o.showtabline") == .int(0))
        #expect(try lua(client, "return vim.o.winheight") == .int(3))
        #expect(try lua(client, "return vim.o.winminheight") == .int(1))
        #expect(try lua(client, "return vim.o.hlsearch") == .bool(false))
        #expect(try lua(client, "return vim.v.this_session") == .string(""))
        #expect(try client.currentFile() == named)
        #expect(try listedFiles(client) == [named])
    }

    @Test func deletedFilesDontComeBack() throws {
        let a = try file("a.txt", "a\n")
        let b = try file("b.txt", "b\n")
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        try client.saveSession(to: sessionPath)
        try FileManager.default.removeItem(atPath: b)

        let (fresh, other) = try freshNvim()
        #expect(try other.restoreSession(from: sessionPath, namedFiles: []) == .restored)

        #expect(try listedFiles(other) == [a])
        withExtendedLifetime(fresh) {}
    }

    @Test func theNamedFileIsInFront() throws {
        let a = try file("a.txt", "a\n")
        let b = try file("b.txt", "b\n")
        let c = try file("c.txt", "c\n")
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        try client.saveSession(to: sessionPath)

        let (fresh, other) = try freshNvim(arguments: [c])
        #expect(try other.restoreSession(from: sessionPath, namedFiles: [c]) == .restored)

        #expect(try other.currentFile() == c)
        #expect(Set(try listedFiles(other)) == [a, b, c])
        withExtendedLifetime(fresh) {}
    }

    @Test func theFirstNamedFileNvimKnowsIsInFront() throws {
        let a = try file("a.txt", "a\n")
        let c = try file("c.txt", "c\n")
        let d = try file("d.txt", "d\n")
        try client.edit(a)
        try client.saveSession(to: sessionPath)

        // As if `-c <cmd>` had been resolved into a named file too.
        let notAFile = folder + "/echo"
        let (fresh, other) = try freshNvim(arguments: ["-c", "echo", c, d])
        #expect(try other.restoreSession(from: sessionPath, namedFiles: [notAFile, c, d]) == .restored)

        #expect(try other.currentFile() == c)
        #expect(Set(try listedFiles(other)) == [a, c, d])
        withExtendedLifetime(fresh) {}
    }

    @Test func aNamedFileThatDoesntExistYetStays() throws {
        let a = try file("a.txt", "a\n")
        try client.edit(a)
        try client.saveSession(to: sessionPath)
        let new = path("new.md")

        let (fresh, other) = try freshNvim(arguments: [new])
        #expect(try other.restoreSession(from: sessionPath, namedFiles: [new]) == .restored)

        #expect(try other.currentFile() == new)
        #expect(Set(try listedFiles(other)) == [a, new])
        withExtendedLifetime(fresh) {}
    }

    @Test func oddFileNamesSurvive() throws {
        let a = try file("a #b [c] %d 'e\" $f.txt", numbered(10))
        let b = try file("dir with space/b\\g.txt", numbered(10))
        let session = path("state/odd 'session' #1 %.vim")
        try client.edit(a)
        try command(client, "vsplit " + escaped(b))
        try client.saveSession(to: session)
        #expect(FileManager.default.fileExists(atPath: session))

        let (fresh, other) = try freshNvim(arguments: [b])
        #expect(try other.restoreSession(from: session, namedFiles: [b]) == .restored)

        #expect(try other.currentFile() == b)
        #expect(Set(try listedFiles(other)) == [a, b])
        #expect(try lua(other, "return vim.fn.argv()") == .array([.string(b)]))
        withExtendedLifetime(fresh) {}
    }

    // MARK: - Helpers

    /// A second nvim, as a later launch would start, and a client for it.
    @Test func waitsUntilNvimHasStarted() throws {
        // `-c` runs after the files load and before VimEnter; its :sleep lets
        // requests through, so nvim answers while it's still starting.
        let (slow, other) = try freshNvim(arguments: ["-c", "sleep 1"])
        let started = Date()
        try other.waitUntilStarted()
        #expect(Date().timeIntervalSince(started) > 0.5)
        #expect(try other.request("nvim_get_vvar", [.string("vim_did_enter")]) == .int(1))
        _ = slow
    }

    @Test func knowsWhetherASessionIsLoaded() throws {
        #expect(try client.isSessionLoaded() == false)
        let mine = try file("mine.vim", "")
        _ = try lua(client, "vim.v.this_session = ...", [.string(mine)])
        #expect(try client.isSessionLoaded() == true)
    }

    @Test func aShortReadTimeoutGivesUpSoon() throws {
        // One connection keeps nvim busy for 2 s; another, with a 0.3 s read
        // timeout, gives up long before nvim gets to it.
        let busy = NvimClient(socketPath: nvim.socketPath)
        let started = Date()
        let busyDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? busy.request("nvim_exec_lua", [.string("vim.uv.sleep(2000)"), .array([])])
            busyDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        let quick = NvimClient(socketPath: nvim.socketPath, connectTimeout: 0.5, readTimeout: 0.3)
        #expect(throws: NvimClient.Failure.connectionLost) { try quick.isSessionLoaded() }
        #expect(Date().timeIntervalSince(started) < 1.5)
        busyDone.wait()
    }

    @Test func waitingForAnNvimThatIsGoneThrows() {
        let gone = NvimClient(socketPath: folder + "/gone.sock", connectTimeout: 0.2)
        #expect(throws: NvimClient.Failure.self) { try gone.waitUntilStarted() }
    }

    private func freshNvim(arguments: [String] = []) throws -> (HeadlessNvim, NvimClient) {
        let fresh = try HeadlessNvim(arguments: arguments)
        return (fresh, NvimClient(socketPath: fresh.socketPath))
    }

    private func path(_ relative: String) -> String {
        folder + "/" + relative
    }

    private func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)\n" }.joined()
    }

    private func file(_ relative: String, _ text: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        return full
    }

    /// A command with a file argument, escaped by nvim itself.
    private func escaped(_ path: String) -> String {
        // Only used to build test commands; the code under test never splices.
        guard case let .string(text)? = try? lua(client, "return vim.fn.fnameescape(...)", [.string(path)]) else {
            return path
        }
        return text
    }

    private func listedFiles(_ client: NvimClient) throws -> [String] {
        guard case let .array(names) = try lua(client, """
            local names = {}
            for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
              if info.name ~= "" then table.insert(names, info.name) end
            end
            return names
            """) else { return [] }
        return names.compactMap { if case let .string(name) = $0 { name } else { nil } }
    }

    private func command(_ client: NvimClient, _ text: String) throws {
        _ = try client.request("nvim_command", [.string(text)])
    }

    private func lua(_ client: NvimClient, _ code: String, _ args: [MessagePackValue] = []) throws -> MessagePackValue {
        try client.request("nvim_exec_lua", [.string(code), .array(args)])
    }
}
