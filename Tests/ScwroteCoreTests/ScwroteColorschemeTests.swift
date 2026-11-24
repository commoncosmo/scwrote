import Foundation
import Testing
@testable import ScwroteCore

/// The nvim runtime folder that holds `colors/scwrote.lua`, in the source tree.
private let runtimeFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Scwrote/Resources/nvim").path

/// A headless nvim with the runtime folder on its `runtimepath`, and a client
/// to ask it things. Nothing holds it but the test, so it stops with the test.
private final class ColorschemeNvim {
    private let nvim: HeadlessNvim
    private let control: NvimClient

    /// `arguments` follow the one that adds the runtime folder.
    init(_ arguments: [String] = []) throws {
        let folder = runtimeFolder.replacingOccurrences(of: " ", with: "\\ ")
        nvim = try HeadlessNvim(arguments: ["--cmd", "set rtp+=\(folder)"] + arguments)
        control = NvimClient(
            socketPath: nvim.socketPath, connectTimeout: 10, queuesNotifications: false, waitsOutTimeouts: true)
        try control.waitUntilStarted()
    }

    deinit {
        control.close()
    }

    @discardableResult
    func lua(_ code: String, _ arguments: [MessagePackValue] = []) throws -> MessagePackValue {
        try control.request("nvim_exec_lua", [.string(code), .array(arguments)])
    }

    func setBackground(_ background: NvimBackground) throws {
        try control.setBackground(background)
    }

    var colorsName: String? {
        get throws {
            if case let .string(name) = try lua("return vim.g.colors_name") { name } else { nil }
        }
    }

    /// The group's attributes with links followed, as `nvim_get_hl` gives them.
    func group(_ name: String) throws -> [String: MessagePackValue] {
        let spec = try control.request(
            "nvim_get_hl",
            [.int(0), .map([.string("name"): .string(name), .string("link"): .bool(false), .string("create"): .bool(false)])])
        guard case let .map(map) = spec else { return [:] }
        var attributes: [String: MessagePackValue] = [:]
        for case let (.string(key), value) in map { attributes[key] = value }
        return attributes
    }

    func color(_ name: String, _ attribute: String) throws -> Int? {
        if case let .int(rgb)? = try group(name)[attribute] { Int(rgb) } else { nil }
    }
}

struct ScwroteColorschemeTests {
    @Test func loadsWarmPaperInLightAndSoftDarkInDark() throws {
        let nvim = try ColorschemeNvim(["--cmd", "set background=light", "-c", "colorscheme scwrote"])
        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.color("Normal", "bg") == 0xf3efe7)

        try nvim.setBackground(.dark)

        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.color("Normal", "bg") == 0x1e1f22)
    }

    @Test func globalsChooseCoolSlateAndNvimDefault() throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "let g:scwrote_light_colors = '\(LightColors.coolSlate.rawValue)'",
            "--cmd", "let g:scwrote_dark_colors = '\(DarkColors.nvimDefault.rawValue)'",
            "--cmd", "set background=light",
            "--cmd", "colorscheme scwrote",
        ])
        #expect(try nvim.color("Normal", "bg") == 0xeef2f6)
        #expect(try nvim.color("ScwroteBrowser", "bg") == 0xe2e8ef)

        try nvim.setBackground(.dark)

        #expect(try nvim.color("Normal", "bg") == 0x14161b)
        #expect(try nvim.color("Normal", "fg") == 0xe0e2ea)
        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.color("ScwroteBrowser", "bg") == nil)
    }

    @Test func unknownGlobalsGiveTheDefaults() throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "let g:scwrote_light_colors = 'purple'",
            "--cmd", "let g:scwrote_dark_colors = 'purple'",
            "--cmd", "set background=light",
            "--cmd", "colorscheme scwrote",
        ])
        #expect(try nvim.color("Normal", "bg") == 0xf3efe7)

        try nvim.setBackground(.dark)

        #expect(try nvim.color("Normal", "bg") == 0x1e1f22)
    }

    @Test func configBackgroundReSourcesThePalette() throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "set background=light", "--cmd", "colorscheme scwrote", "-c", "set background=dark",
        ])
        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.color("Normal", "bg") == 0x1e1f22)
    }

    @Test func aConfigColorschemeReplacesIt() throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "set background=light", "--cmd", "colorscheme scwrote", "-c", "colorscheme desert",
        ])
        #expect(try nvim.colorsName == "desert")
    }

    @Test func aConfigsOwnHighlightsSurvive() throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "set background=light", "--cmd", "colorscheme scwrote", "-c", "hi Comment guifg=#00ff00",
        ])
        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.color("Comment", "fg") == 0x00ff00)
    }

    /// Piece 2's ownership check reads `background`'s script ID: still the
    /// `--cmd` one (-2) after the colorscheme loads, in every palette.
    @Test(arguments: [
        ["--cmd", "set background=light"],
        ["--cmd", "let g:scwrote_light_colors = 'coolSlate'", "--cmd", "set background=light"],
        ["--cmd", "set background=dark"],
        ["--cmd", "let g:scwrote_dark_colors = 'nvimDefault'", "--cmd", "set background=dark"],
    ])
    func theColorschemeNeverSetsBackground(setup: [String]) throws {
        let nvim = try ColorschemeNvim(setup + ["--cmd", "colorscheme scwrote"])
        #expect(try nvim.colorsName == "scwrote")
        #expect(try nvim.lua("return vim.api.nvim_get_option_info2('background', {}).last_set_sid") == .int(-2))
    }

    /// Every group nvim's built-in default gives its own colors (rather than a
    /// link), in either background, is in each palette's groups.
    @Test func everyPaletteCoversNvimsDefaultGroups() throws {
        let nvim = try ColorschemeNvim()
        let result = try nvim.lua("""
            local names = {}
            for _, background in ipairs({ "dark", "light" }) do
              vim.o.background = background
              vim.cmd("hi clear")
              for name, spec in pairs(vim.api.nvim_get_hl(0, {})) do
                if not spec.link then names[name] = true end
              end
            end
            local missing, palettes = {}, 0
            for id, palette in pairs(require("scwrote.colors").palettes) do
              palettes = palettes + 1
              local groups = require("scwrote.groups")(palette)
              local lacking = {}
              for name in pairs(names) do
                if groups[name] == nil then table.insert(lacking, name) end
              end
              table.sort(lacking)
              if #lacking > 0 then missing[id] = table.concat(lacking, " ") end
            end
            return { names = vim.tbl_count(names), palettes = palettes, missing = missing }
            """)
        guard case let .map(map) = result else { Issue.record("no result: \(result)"); return }
        #expect(map[.string("palettes")] == .int(3))
        // nvim 0.12 has about 90; a handful would mean the query went wrong.
        if case let .int(count)? = map[.string("names")] { #expect(count > 50) } else { Issue.record("no count") }
        // An empty Lua table comes back as an empty array.
        let missing = map[.string("missing")]
        #expect(missing == .array([]) || missing == .map([:]), "missing groups: \(String(describing: missing))")
    }

    @Test(arguments: [
        (global: "scwrote_light_colors", value: LightColors.warmPaper.rawValue, background: NvimBackground.light, floor: 7.0),
        (global: "scwrote_light_colors", value: LightColors.coolSlate.rawValue, background: NvimBackground.light, floor: 7.0),
        (global: "scwrote_dark_colors", value: DarkColors.softDark.rawValue, background: NvimBackground.dark, floor: 8.0),
    ])
    func everyPaletteMeetsTheContrastFloors(
        palette: (global: String, value: String, background: NvimBackground, floor: Double)
    ) throws {
        let nvim = try ColorschemeNvim([
            "--cmd", "let g:\(palette.global) = '\(palette.value)'",
            "--cmd", "set background=\(palette.background.rawValue)",
            "--cmd", "colorscheme scwrote",
        ])
        func color(_ group: String, _ attribute: String) throws -> RGBColor {
            let rgb = try #require(try nvim.color(group, attribute), "\(palette.value): \(group) has no \(attribute)")
            return RGBColor(rgb: rgb)
        }
        func expectContrast(_ group: String, on background: RGBColor, atLeast floor: Double, _ what: String) throws {
            let ratio = try color(group, "fg").contrastRatio(with: background)
            #expect(ratio >= floor, "\(palette.value): \(group) on \(what) is \(ratio), under \(floor)")
        }

        let background = try color("Normal", "bg")
        try expectContrast("Normal", on: background, atLeast: palette.floor, "Normal")
        for group in ["Comment", "LineNr"] {
            try expectContrast(group, on: background, atLeast: 3, "Normal")
        }
        for group in ["Statement", "Keyword", "Function", "String", "Number", "Type", "@property", "Constant"] {
            try expectContrast(group, on: background, atLeast: 4.5, "Normal")
        }
        try expectContrast("Normal", on: color("Visual", "bg"), atLeast: 4.5, "Visual")

        let browser = try color("ScwroteBrowser", "bg")
        #expect(browser != background, "\(palette.value): the browser shade is the editor's")
        for group in ["Normal", "Directory"] {
            try expectContrast(group, on: browser, atLeast: palette.floor, "ScwroteBrowser")
        }

        // Diffs: their own shades, and their text readable on them.
        let visual = try color("Visual", "bg")
        for group in ["DiffAdd", "DiffChange", "DiffDelete", "DiffText"] {
            let shade = try color(group, "bg")
            #expect(shade != visual, "\(palette.value): \(group) has Visual's background")
            let text = try nvim.color(group, "fg").map(RGBColor.init(rgb:)) ?? color("Normal", "fg")
            let ratio = text.contrastRatio(with: shade)
            #expect(ratio >= 4.5, "\(palette.value): \(group)'s text on it is \(ratio), under 4.5")
        }
    }
}
