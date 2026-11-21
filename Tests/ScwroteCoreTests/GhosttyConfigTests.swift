import Foundation
import Testing
@testable import ScwroteCore

struct GhosttyConfigTests {
    /// A fresh folder holding empty theme files with the given names.
    private func themeFolder(_ names: String...) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scwrote-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        return folder.path
    }

    @Test func candidatePathsFollowGhosttysOwnOrder() {
        let paths = GhosttyConfig.candidatePaths(home: "/Users/me", xdgConfigHome: nil)

        #expect(paths == [
            "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/.config/ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
        ])
    }

    @Test func candidatePathsHonorXDGConfigHome() {
        let paths = GhosttyConfig.candidatePaths(home: "/Users/me", xdgConfigHome: "/cfg")

        #expect(paths.first == "/cfg/ghostty/config.ghostty")
    }

    @Test func themeNameBecomesThePathOfTheThemeFile() throws {
        let folder = try themeFolder("Afterglow")

        let resolved = GhosttyConfig.resolvingThemes(
            in: "theme = Afterglow\nfont-size = 14",
            themeDirectories: [folder]
        )

        #expect(resolved == "theme = \(folder)/Afterglow\nfont-size = 14")
    }

    @Test func earlierThemeFolderWins() throws {
        let userFolder = try themeFolder("Afterglow")
        let appFolder = try themeFolder("Afterglow")

        let resolved = GhosttyConfig.resolvingThemes(
            in: "theme = Afterglow",
            themeDirectories: [userFolder, appFolder]
        )

        #expect(resolved == "theme = \(userFolder)/Afterglow")
    }

    @Test func lightAndDarkThemesAreBothResolved() throws {
        let folder = try themeFolder("Day", "Night")

        let resolved = GhosttyConfig.resolvingThemes(
            in: "theme = light:Day,dark:Night",
            themeDirectories: [folder]
        )

        #expect(resolved == "theme = light:\(folder)/Day,dark:\(folder)/Night")
    }

    @Test func loadJoinsExistingConfigFilesInOrderAndResolvesThemes() throws {
        let home = try themeFolder()
        let xdgFile = "\(home)/.config/ghostty/config"
        let appFile = "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        for file in [xdgFile, appFile] {
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        }
        try "font-size = 15".write(toFile: xdgFile, atomically: true, encoding: .utf8)
        try "theme = Afterglow".write(toFile: appFile, atomically: true, encoding: .utf8)
        let themes = try themeFolder("Afterglow")

        let loaded = GhosttyConfig.load(home: home, xdgConfigHome: nil, themeDirectories: [themes])

        #expect(loaded == "font-size = 15\ntheme = \(themes)/Afterglow")
    }

    @Test func loadReturnsNilWithoutAnyConfigFile() throws {
        let home = try themeFolder()

        #expect(GhosttyConfig.load(home: home, xdgConfigHome: nil, themeDirectories: []) == nil)
    }

    /// Ghostty's per-surface `command` option forces wait-after-command on, so
    /// the window would sit at "Process exited" after `:q`. Passing the command
    /// through config lets wait-after-command stay off.
    @Test func editorConfigRunsTheCommandAndClosesWhenItExits() throws {
        let config = try GhosttyConfig.editorConfig(userConfig: "theme = /t/Afterglow", command: "'nvim' 'a.md'")

        #expect(config == "theme = /t/Afterglow\ncommand = 'nvim' 'a.md'\nwait-after-command = false")
    }

    @Test func editorConfigWorksWithoutAUserConfig() throws {
        let config = try GhosttyConfig.editorConfig(userConfig: nil, command: "'nvim'")

        #expect(config == "command = 'nvim'\nwait-after-command = false")
    }

    /// A file name may contain a line break. In the config it would end the
    /// `command =` line, and the rest would be read as config lines of its own,
    /// such as a second `command =` that replaces nvim.
    @Test(arguments: ["\n", "\r"])
    func editorConfigRefusesACommandThatSpansLines(lineBreak: String) {
        let command = "'nvim' 'notes\(lineBreak)command = /tmp/evil.md'"

        #expect(throws: GhosttyConfig.UnsafeCommand.self) {
            try GhosttyConfig.editorConfig(userConfig: nil, command: command)
        }
    }

    @Test func unknownThemeIsLeftForGhosttyToReport() throws {
        let folder = try themeFolder()

        let resolved = GhosttyConfig.resolvingThemes(
            in: "theme = Nonexistent",
            themeDirectories: [folder]
        )

        #expect(resolved == "theme = Nonexistent")
    }

    // MARK: - Top padding

    @Test func topPaddingDefaultsToGhosttysTwoPoints() {
        #expect(GhosttyConfig.topPadding(in: "theme = Afterglow") == 2)
        #expect(GhosttyConfig.topPadding(in: nil) == 2)
    }

    @Test func topPaddingReadsASingleValue() {
        #expect(GhosttyConfig.topPadding(in: "window-padding-y = 6") == 6)
    }

    @Test func topPaddingIsTheFirstOfTwoValues() {
        #expect(GhosttyConfig.topPadding(in: "window-padding-y = 3,10") == 3)
    }

    @Test func laterPaddingLinesWin() {
        #expect(GhosttyConfig.topPadding(in: "window-padding-y = 6\nwindow-padding-y = 1") == 1)
    }

    @Test func unreadablePaddingKeepsThePreviousValue() {
        #expect(GhosttyConfig.topPadding(in: "window-padding-y = 6\nwindow-padding-y = lots") == 6)
    }
}
