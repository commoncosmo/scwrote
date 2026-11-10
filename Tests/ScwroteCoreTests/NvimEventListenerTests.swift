import Foundation
import Testing
@testable import ScwroteCore

/// Collects what a listener reports, from its background thread.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PreviewEvent] = []
    private var _endCount = 0

    var events: [PreviewEvent] { lock.withLock { _events } }
    var endCount: Int { lock.withLock { _endCount } }

    var buffers: [BufferSnapshot] {
        events.compactMap { if case let .buffer(snapshot) = $0 { snapshot } else { nil } }
    }

    func record(_ event: PreviewEvent) { lock.withLock { _events.append(event) } }
    func recordEnd() { lock.withLock { _endCount += 1 } }

    /// Polls until `predicate` holds, for at most `timeout` seconds.
    func waitFor(timeout: TimeInterval = 2, _ predicate: (EventLog) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(self) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}

/// A headless nvim editing a temp file, with a listener attached.
private final class Session {
    let nvim: HeadlessNvim
    let client: NvimClient
    let listener: NvimEventListener
    let log = EventLog()
    let folder: URL
    let file: String

    init(contents: String, name: String = "notes.md") throws {
        nvim = try HeadlessNvim()
        client = NvimClient(socketPath: nvim.socketPath)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote events \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try client.edit(url.path)
        // nvim reports the real path: the temp folder /var/... is a symlink
        // to /private/var/...
        file = realpath(url.path)

        listener = NvimEventListener(socketPath: nvim.socketPath)
        let log = log
        listener.start(onEvent: { log.record($0) }, onEnd: { log.recordEnd() })
    }

    deinit {
        listener.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func input(_ keys: String) throws {
        _ = try client.request("nvim_input", [.string(keys)])
    }

    func lua(_ code: String, _ args: [MessagePackValue] = []) throws -> MessagePackValue {
        try client.request("nvim_exec_lua", [.string(code), .array(args)])
    }

    /// Waits for the buffer event sent when the listener installs itself.
    func waitUntilListening() -> Bool {
        log.waitFor { !$0.buffers.isEmpty }
    }
}

@Suite(.enabled(if: nvimPath != nil, "needs nvim on PATH"))
struct NvimEventListenerTests {
    @Test func startingOnARealFileSendsItsBuffer() throws {
        let session = try Session(contents: "# hi\n")

        #expect(session.waitUntilListening())
        let first = try #require(session.log.buffers.first)
        #expect(first.path == session.file)
        #expect(first.filetype == "markdown")
        #expect(first.text == "# hi")
        #expect(first.isModified == false)
        #expect(first.cursor == CursorPosition(line: 1, column: 0))
    }

    @Test func typingSendsModifiedAtOnceButTextOnlyOnEsc() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())

        try session.input("ohello")
        #expect(session.log.waitFor { $0.events.contains(.modified(path: session.file, isModified: true)) })
        // The cursor ends after "hello", so every key has been handled.
        #expect(session.log.waitFor {
            $0.events.contains(.cursor(path: session.file, CursorPosition(line: 2, column: 5)))
        })
        #expect(!session.log.buffers.contains { $0.text?.contains("hello") == true })

        try session.input("<Esc>")
        #expect(session.log.waitFor { $0.buffers.contains { $0.text == "# hi\nhello" } })
    }

    @Test func normalModeEditsSendText() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())

        try session.input("dd")

        #expect(session.log.waitFor { $0.buffers.contains { $0.text == "" && $0.isModified } })
    }

    @Test func savingClearsModified() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())

        try session.input("ox<Esc>:w<CR>")

        #expect(session.log.waitFor { $0.buffers.contains { $0.text == "# hi\nx" && !$0.isModified } })
        #expect(session.log.buffers.last?.isModified == false)
        #expect(session.log.events.contains(.modified(path: session.file, isModified: false)))
    }

    @Test func cursorMovesAreSent() throws {
        let session = try Session(contents: "one\ntwo\n")
        #expect(session.waitUntilListening())

        try session.input("j")

        #expect(session.log.waitFor {
            $0.events.contains(.cursor(path: session.file, CursorPosition(line: 2, column: 0)))
        })
    }

    @Test func cursorColumnsCountCharactersNotBytes() throws {
        let session = try Session(contents: "é,b\n")
        #expect(session.waitUntilListening())

        try session.input("$")

        #expect(session.log.waitFor {
            $0.events.contains(.cursor(path: session.file, CursorPosition(line: 1, column: 2)))
        })
    }

    @Test func helpAndFloatingWindowsAreIgnored() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())
        let other = session.folder.appendingPathComponent("other.md").path
        try Data("# other\n".utf8).write(to: URL(fileURLWithPath: other))

        try session.input(":help<CR>")
        #expect(session.log.waitFor { _ in
            (try? session.lua("return vim.bo.buftype")) == .string("help")
        })
        // A scratch buffer in a float, then a real file in a float: neither counts.
        _ = try session.lua("""
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
            """)
        _ = try session.lua("""
            local buf = vim.fn.bufadd(...)
            vim.fn.bufload(buf)
            vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
            """, [.string(other)])
        try session.input("$")
        #expect(try session.lua("return vim.api.nvim_buf_get_name(0)") == .string(realpath(other)))

        // Give anything that would be sent time to arrive.
        Thread.sleep(forTimeInterval: 0.5)
        let strays = session.log.events.filter { event in
            switch event {
            case let .buffer(snapshot): snapshot.path != session.file
            case let .cursor(path, _): path != session.file
            case .modified: false
            }
        }
        #expect(strays.isEmpty)
    }

    @Test func hugeBuffersAreSentWithoutText() throws {
        let line = String(repeating: "a", count: 99) + "\n"
        let lineCount = PreviewLimits.maxBufferBytes / line.utf8.count + 1
        let session = try Session(contents: String(repeating: line, count: lineCount), name: "huge.txt")

        #expect(session.waitUntilListening())
        let first = try #require(session.log.buffers.first)
        #expect(first.path == session.file)
        #expect(first.text == nil)
    }

    @Test func nvimExitingEndsTheListener() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())

        try session.input(":qa!<CR>")

        #expect(session.log.waitFor { $0.endCount == 1 })
    }

    @Test func stoppingEndsTheListenerOnce() throws {
        let session = try Session(contents: "# hi\n")
        #expect(session.waitUntilListening())

        session.listener.stop()

        // Well inside the 5 s read timeout: stopping wakes the blocked read.
        #expect(session.log.waitFor(timeout: 1) { $0.endCount == 1 })
        session.listener.stop()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(session.log.endCount == 1)
    }

    /// nvim takes the connection at once but answers nothing until its
    /// startup is done, which a plugin manager's first run can stretch past
    /// the 5 s read timeout.
    @Test func aSlowStartupIsWaitedOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote events \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.md")
        try Data("# hi\n".utf8).write(to: file)
        let nvim = try HeadlessNvim(arguments: ["--cmd", "lua vim.uv.sleep(6000)", file.path])
        let log = EventLog()
        let listener = NvimEventListener(socketPath: nvim.socketPath)
        defer { listener.stop() }

        listener.start(onEvent: { log.record($0) }, onEnd: { log.recordEnd() })

        #expect(log.waitFor(timeout: 12) { !$0.buffers.isEmpty })
        #expect(log.buffers.first?.path == realpath(file.path))
        #expect(log.endCount == 0)
    }

    @Test func aSocketThatNeverAppearsEndsTheListener() throws {
        let log = EventLog()
        let listener = NvimEventListener(socketPath: NSTemporaryDirectory() + "sn-missing.sock", connectTimeout: 0.2)

        listener.start(onEvent: { log.record($0) }, onEnd: { log.recordEnd() })

        #expect(log.waitFor { $0.endCount == 1 })
        #expect(log.events.isEmpty)
    }

    @Test func autocommandsRemoveThemselvesOnceTheListenerIsGone() throws {
        let session = try Session(contents: "one\ntwo\n")
        #expect(session.waitUntilListening())

        session.listener.stop()

        // nvim notices the closed channel on the next event it tries to send.
        var down = true
        #expect(session.log.waitFor { _ in
            try? session.input(down ? "j" : "k")
            down.toggle()
            return (try? session.lua("return (pcall(vim.api.nvim_get_autocmds, { group = 'ScwrotePreview' }))")) == .bool(false)
        })
        #expect(try session.lua("return vim.v.errmsg") == .string(""))
    }
}
