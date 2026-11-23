import Foundation
import Testing
@testable import ScwroteCore

private let patience: TimeInterval = 30

/// A headless nvim with a client that has ColorAutocommands installed, and
/// everything it reports, collected on a background thread.
private final class Reports: @unchecked Sendable {
    let nvim: HeadlessNvim
    private let listening: NvimClient
    private let control: NvimClient
    private let lock = NSLock()
    private var _all: [NvimColors] = []

    var all: [NvimColors] { lock.withLock { _all } }

    /// `arguments` go to nvim; the autocommands are installed as soon as it
    /// answers, which is after its startup.
    init(arguments: [String] = []) throws {
        nvim = try HeadlessNvim(arguments: arguments)
        listening = NvimClient(
            socketPath: nvim.socketPath, connectTimeout: 10, queuesNotifications: true, waitsOutTimeouts: true
        )
        control = NvimClient(
            socketPath: nvim.socketPath, connectTimeout: 10, queuesNotifications: false, waitsOutTimeouts: true
        )
        let channel = try listening.channelID()
        let thread = Thread { [self] in
            while let notification = try? listening.nextNotification() {
                if let event = PreviewEvent(method: notification.method, params: notification.params),
                    case let .colors(colors) = event
                {
                    lock.withLock { _all.append(colors) }
                }
            }
        }
        thread.start()
        _ = try control.request(
            "nvim_exec_lua", [.string(ColorAutocommands.lua), .array(ColorAutocommands.arguments(channel: channel))]
        )
    }

    deinit {
        listening.close()
        control.close()
    }

    func command(_ command: String) throws {
        _ = try control.request("nvim_command", [.string(command)])
    }

    /// Waits for a report after the first `count` ones that satisfies `matches`.
    func report(after count: Int, where matches: (NvimColors) -> Bool = { _ in true }) -> NvimColors? {
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            if let found = all.dropFirst(count).first(where: matches) { return found }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

struct NvimColorReportTests {
    @Test func installReportsTheCurrentColors() throws {
        let reports = try Reports()

        let first = try #require(reports.report(after: 0))

        #expect(first.groups["Normal"]?.bg == RGBColor(rgb: 0x14161b))
        #expect(first.background == "dark")
        #expect(Set(first.groups.keys) == Set(NvimColors.groupNames))
    }

    @Test func settingBackgroundLightReports() throws {
        let reports = try Reports()
        _ = try #require(reports.report(after: 0))

        try reports.command("set background=light")

        let light = try #require(reports.report(after: 1) { $0.background == "light" })
        #expect(light.groups["Normal"]?.bg == RGBColor(rgb: 0xe0e2ea))
    }

    @Test func colorschemeChangeReports() throws {
        let reports = try Reports()
        let first = try #require(reports.report(after: 0))

        try reports.command("colorscheme morning")

        let morning = try #require(reports.report(after: 1) { $0.groups["Normal"] != first.groups["Normal"] })
        #expect(morning.groups["Normal"] != first.groups["Normal"])
    }

    @Test func transparentNormalReportsNoBackground() throws {
        let reports = try Reports()
        _ = try #require(reports.report(after: 0))

        try reports.command("hi Normal guibg=NONE")
        try reports.command("doautocmd ColorScheme")

        let transparent = try #require(reports.report(after: 1) { $0.groups["Normal"]?.bg == nil })
        #expect(transparent.groups["Normal"]?.bg == nil)
    }

    @Test func linkedGroupsResolve() throws {
        let reports = try Reports()
        let first = try #require(reports.report(after: 0))
        let visual = try #require(first.groups["Visual"])
        #expect(visual.bg != nil)

        try reports.command("hi! link Directory Visual")
        try reports.command("doautocmd ColorScheme")

        let linked = try #require(reports.report(after: 1) { $0.groups["Directory"] == visual })
        #expect(linked.groups["Directory"] == visual)
    }

    /// The report that matters is the last one: the config's `set background`
    /// runs during startup, and whenever the autocommands go in, the final
    /// state must reach scwrote.
    @Test func aColorschemeSetDuringStartupIsReported() throws {
        let reports = try Reports(arguments: ["-c", "set background=light"])

        let light = reports.report(after: 0) { $0.background == "light" }
        #expect(light != nil)
        Thread.sleep(forTimeInterval: 1)
        #expect(reports.all.last?.background == "light")
        #expect(reports.all.last?.groups["Normal"]?.bg == RGBColor(rgb: 0xe0e2ea))
    }
}
