import Foundation
import Testing
@testable import ScwroteCore

private let patience: TimeInterval = 30

/// A headless nvim with a listening client, and every event reported to it,
/// collected on a background thread. Nothing is installed until a test asks.
private final class Events: @unchecked Sendable {
    let nvim: HeadlessNvim
    private let listening: NvimClient
    let control: NvimClient
    private let channel: Int64
    /// What the listening thread collects. The thread holds only this and the
    /// connection, never `Events`, so `Events.deinit` runs and stops nvim.
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var all: [PreviewEvent] = []
    }
    private let sink = Sink()

    var all: [PreviewEvent] { sink.lock.withLock { sink.all } }

    var owners: [Bool] {
        self.all.compactMap { if case let .backgroundOwner(owned) = $0 { owned } else { nil } }
    }

    var colors: [NvimColors] {
        self.all.compactMap { if case let .colors(colors) = $0 { colors } else { nil } }
    }

    /// `arguments` go to nvim.
    init(arguments: [String] = []) throws {
        nvim = try HeadlessNvim(arguments: arguments)
        listening = NvimClient(
            socketPath: nvim.socketPath, connectTimeout: 10, queuesNotifications: true, waitsOutTimeouts: true
        )
        control = NvimClient(
            socketPath: nvim.socketPath, connectTimeout: 10, queuesNotifications: false, waitsOutTimeouts: true
        )
        channel = try listening.channelID()
        let sink = sink
        let listening = listening
        let thread = Thread {
            while let notification = try? listening.nextNotification() {
                if let event = PreviewEvent(method: notification.method, params: notification.params) {
                    sink.lock.withLock { sink.all.append(event) }
                }
            }
        }
        thread.start()
    }

    deinit {
        listening.close()
        control.close()
    }

    func installOwnership() throws {
        _ = try control.request(
            "nvim_exec_lua", [.string(BackgroundOwnership.lua), .array(BackgroundOwnership.arguments(channel: channel))]
        )
    }

    func installColors() throws {
        _ = try control.request(
            "nvim_exec_lua", [.string(ColorAutocommands.lua), .array(ColorAutocommands.arguments(channel: channel))]
        )
    }

    func background() throws -> MessagePackValue {
        try control.request("nvim_get_option_value", [.string("background"), .map([:])])
    }

    /// Waits for the first ownership report.
    func owner() -> Bool? {
        wait { $0.owners.first }
    }

    /// Waits for a colors report after the first `count` ones that satisfies `matches`.
    func colors(after count: Int, where matches: @escaping (NvimColors) -> Bool = { _ in true }) -> NvimColors? {
        wait { $0.colors.dropFirst(count).first(where: matches) }
    }

    /// Lets anything nvim has queued for the listening channel arrive.
    func settle() throws {
        _ = try control.request("nvim_exec_lua", [.string("vim.wait(50) return 1"), .array([])])
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func wait<T>(for found: (Events) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            if let value = found(self) { return value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

struct BackgroundOwnershipTests {
    @Test func backgroundSetByCmdIsOwned() throws {
        let events = try Events(arguments: ["--cmd", "set background=light"])
        try events.installOwnership()

        #expect(events.owner() == true)
        #expect(try events.background() == .string("light"))
    }

    @Test func aConfigThatSetsBackgroundOwnsIt() throws {
        let events = try Events(arguments: ["--cmd", "set background=light", "-c", "set background=dark"])
        try events.installOwnership()

        #expect(events.owner() == false)
        #expect(try events.background() == .string("dark"))
    }

    @Test func aLuaConfigThatSetsBackgroundOwnsIt() throws {
        let events = try Events(arguments: ["--cmd", "set background=light", "-c", "lua vim.o.background = 'dark'"])
        try events.installOwnership()

        #expect(events.owner() == false)
    }

    @Test func installedAfterStartupStillReports() throws {
        let events = try Events(arguments: ["--cmd", "set background=light"])
        try events.control.waitUntilStarted()
        #expect(try events.control.request("nvim_get_vvar", [.string("vim_did_enter")]) == .int(1))

        try events.installOwnership()

        #expect(events.owner() == true)
        try events.settle()
        #expect(events.owners.count == 1)
    }

    /// Installed while startup is held up (as a synchronous plugin install
    /// holds it), the report waits for `VimEnter`, so it sees what the rest
    /// of the config sets.
    @Test func installedDuringStartupReportsOnceAtVimEnter() throws {
        let events = try Events(arguments: [
            "--cmd", "set background=light",
            "-c", "lua vim.wait(30000, function() return vim.g.scwrote_go end)",
            "-c", "set background=dark",
        ])
        try events.installOwnership()
        #expect(try events.control.request("nvim_get_vvar", [.string("vim_did_enter")]) == .int(0))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(events.owners.isEmpty)

        _ = try events.control.request("nvim_set_var", [.string("scwrote_go"), .bool(true)])

        #expect(events.owner() == false)
        try events.settle()
        #expect(events.owners.count == 1)
    }

    @Test func setBackgroundOverRPCSendsAColorsReport() throws {
        let events = try Events()
        try events.installColors()
        let first = try #require(events.colors(after: 0))

        try events.control.setBackground(.light)

        let light = try #require(events.colors(after: 1) { $0.background == "light" })
        #expect(light.groups["Normal"]?.bg != first.groups["Normal"]?.bg)
    }
}
