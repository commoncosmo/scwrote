import Foundation

/// Reads the user's own Ghostty config so scredit windows look like their Ghostty.
public enum GhosttyConfig {
    /// Config files Ghostty itself reads on macOS, in the order it reads them
    /// (later files override earlier ones).
    public static func candidatePaths(home: String, xdgConfigHome: String?) -> [String] {
        let xdg = xdgConfigHome ?? "\(home)/.config"
        let appSupport = "\(home)/Library/Application Support/com.mitchellh.ghostty"
        return [
            "\(xdg)/ghostty/config.ghostty",
            "\(xdg)/ghostty/config",
            "\(appSupport)/config.ghostty",
            "\(appSupport)/config",
        ]
    }

    /// Folders Ghostty looks in for a `theme = Name`: the user's own themes,
    /// then the ones bundled with Ghostty.app.
    public static func themeDirectories(home: String, xdgConfigHome: String?) -> [String] {
        let xdg = xdgConfigHome ?? "\(home)/.config"
        return [
            "\(xdg)/ghostty/themes",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
    }

    /// The embedded library ships without Ghostty's theme files, so a bare theme
    /// name would not resolve. Rewrites each name to the path of its theme file.
    public static func resolvingThemes(in contents: String, themeDirectories: [String]) -> String {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "theme"
                else { return String(line) }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                let resolved = value
                    .split(separator: ",")
                    .map { resolveThemePart(String($0), in: themeDirectories) }
                    .joined(separator: ",")
                return "theme = \(resolved)"
            }
            .joined(separator: "\n")
    }

    /// One `Name`, `light:Name` or `dark:Name` entry.
    private static func resolveThemePart(_ part: String, in directories: [String]) -> String {
        var prefix = ""
        var name = part
        for mode in ["light:", "dark:"] where part.hasPrefix(mode) {
            prefix = mode
            name = String(part.dropFirst(mode.count))
        }
        guard !name.hasPrefix("/") else { return part }
        let found = directories
            .map { "\($0)/\(name)" }
            .first { FileManager.default.fileExists(atPath: $0) }
        return prefix + (found ?? name)
    }

    /// The config for one editor window: the user's config, then the command to
    /// run, appended last so it wins over any `command` the user set for Ghostty.
    ///
    /// The command goes here instead of the surface's own `command` option
    /// because Ghostty's embedding API forces wait-after-command on whenever a
    /// surface is given a command, which would leave the window at "Process
    /// exited" after `:q` instead of closing it.
    /// The command would span more than one config line.
    public struct UnsafeCommand: Error, Equatable {}

    public static func editorConfig(userConfig: String?, command: String) throws -> String {
        // A line break (from a file name, say) would end the `command =` line
        // and turn the rest into config lines of its own.
        guard !command.contains(where: \.isNewline) else { throw UnsafeCommand() }
        let editorLines = "command = \(command)\nwait-after-command = false"
        guard let userConfig else { return editorLines }
        return "\(userConfig)\n\(editorLines)"
    }

    /// Points between the top of the terminal and its first line: the first
    /// of `window-padding-y`'s values (`2` or `2,4`), Ghostty's default 2 if
    /// unset. A value Ghostty couldn't read leaves the previous one in place.
    public static func topPadding(in config: String?) -> Double {
        var top = 2.0
        for line in (config ?? "").split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "window-padding-y" else { continue }
            let first = parts[1].split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let value = Double(first) { top = value }
        }
        return top
    }

    /// The user's Ghostty config, ready to hand to the embedded library, or nil
    /// if they have none (the library's defaults apply).
    public static func load(home: String, xdgConfigHome: String?, themeDirectories: [String]) -> String? {
        let files = candidatePaths(home: home, xdgConfigHome: xdgConfigHome)
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard !files.isEmpty else { return nil }
        return resolvingThemes(in: files.joined(separator: "\n"), themeDirectories: themeDirectories)
    }
}
