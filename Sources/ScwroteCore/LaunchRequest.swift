import Foundation

/// What `scwrote <args>` asked for, turned into what the window should run.
public struct LaunchRequest: Equatable, Sendable {
    /// Folder nvim starts in.
    public var workingDirectory: String
    /// Arguments handed to nvim.
    public var nvimArguments: [String]
    /// Window title until nvim sets its own.
    public var title: String
    /// Folder the file browser shows.
    public var browserRoot: String
    /// Open with the file browser filling the window.
    public var startsInBrowser: Bool
    /// False with `--fresh`: this launch doesn't reopen the last session.
    public var restoresSession: Bool
    /// Absolute paths of the files a file launch names, in order; empty for a folder launch.
    public var namedFiles: [String]
    /// False when nvim's flags set up its windows themselves (`-d`, `-o`,
    /// `-O`, `-p`, `-q`, `-t`): a session would rebuild them, so nvim's side
    /// is neither loaded nor saved for this window. The window side still is.
    public var managesNvimSession: Bool

    public init(
        workingDirectory: String,
        nvimArguments: [String],
        title: String,
        browserRoot: String,
        startsInBrowser: Bool,
        restoresSession: Bool = true,
        namedFiles: [String] = [],
        managesNvimSession: Bool = true
    ) {
        self.workingDirectory = workingDirectory
        self.nvimArguments = nvimArguments
        self.title = title
        self.browserRoot = browserRoot
        self.startsInBrowser = startsInBrowser
        self.restoresSession = restoresSession
        self.namedFiles = namedFiles
        self.managesNvimSession = managesNvimSession
    }

    /// No path, or a single folder, starts in the file browser on that folder,
    /// which also becomes nvim's working directory (like opening a project).
    /// Anything else goes to nvim exactly as typed, from the shell's folder, so
    /// `scwrote <files>` behaves like `nvim <files>` in that shell.
    public static func resolve(
        arguments: [String],
        currentDirectory: String,
        isDirectory: (String) -> Bool
    ) -> LaunchRequest {
        // `--fresh` is scwrote's own, so it's taken out before anything else.
        let restoresSession = !arguments.contains("--fresh")
        let arguments = arguments.filter { $0 != "--fresh" }
        let managesNvimSession = !arguments.prefix { $0 != "--" }.contains(where: setsUpWindows)

        let isFlag = { (argument: String) in argument.hasPrefix("+") || argument.hasPrefix("-") }
        let paths = arguments.filter { !isFlag($0) }

        let folder: String? = switch paths.count {
        case 0: currentDirectory
        case 1: absolute(paths[0], from: currentDirectory)
        default: nil
        }
        if let folder, isDirectory(folder) || paths.isEmpty {
            return LaunchRequest(
                workingDirectory: folder,
                nvimArguments: arguments.filter(isFlag),
                title: URL(fileURLWithPath: folder).lastPathComponent,
                browserRoot: folder,
                startsInBrowser: true,
                restoresSession: restoresSession,
                managesNvimSession: managesNvimSession
            )
        }
        return LaunchRequest(
            workingDirectory: currentDirectory,
            nvimArguments: arguments,
            title: URL(fileURLWithPath: paths.first ?? currentDirectory).lastPathComponent,
            browserRoot: currentDirectory,
            startsInBrowser: false,
            restoresSession: restoresSession,
            namedFiles: paths.map { absolute($0, from: currentDirectory) },
            managesNvimSession: managesNvimSession
        )
    }

    /// This request with the settings read at launch: Reopen where I left
    /// off turned off makes it fresh, as `--fresh` does (the session is still
    /// saved). Turned on, the request is unchanged, so `--fresh` still wins.
    public func honoring(_ settings: Settings) -> LaunchRequest {
        var request = self
        if !settings.reopensFolders { request.restoresSession = false }
        return request
    }

    /// nvim's flags that set up its windows: `-d`, `-o`, `-O` and `-p`, each
    /// with an optional count (`-O3`), and `-q` and `-t`, each with or
    /// without its value attached (`-qerrors.txt`, `-tmain`).
    private static func setsUpWindows(_ argument: String) -> Bool {
        let characters = Array(argument)
        guard characters.count >= 2, characters[0] == "-" else { return false }
        switch characters[1] {
        case "d", "o", "O", "p": return characters.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
        case "q", "t": return true
        default: return false
        }
    }

    /// The command Ghostty runs. nvim listens on `listenAddress` so scwrote can
    /// talk to it, and starts in scwrote's colorscheme: `--cmd`s, which run
    /// before the user's config (and their own `--cmd`s), put the runtime
    /// folder on `runtimepath` (and in `g:scwrote_runtime`) and set the colors
    /// chosen for each background, set `background` (its own `set`, so
    /// `BackgroundOwnership` sees a `--cmd` set it), then load the
    /// colorscheme. A config that picks its own colorscheme or `background`
    /// overrides them. A config that rebuilds `runtimepath` (lazy.nvim does by
    /// default) drops the folder, so a `VimEnter` autocommand puts it back.
    /// Ghostty hands the command to a shell, so every word is single-quoted to
    /// keep spaces and quotes in paths intact.
    public func shellCommand(nvimPath: String, listenAddress: String, colors: LaunchColors) -> String {
        // A comma separates runtimepath's folders; `\,` keeps one in a name.
        let folder = colors.runtimeFolder.replacingOccurrences(of: ",", with: #"\,"#)
        let setup = "lua local folder = [==[\(folder)]==]"
            + " vim.opt.runtimepath:append(folder)"
            + " vim.g.scwrote_runtime = [==[\(colors.runtimeFolder)]==]"
            + " vim.g.scwrote_light_colors = \"\(colors.light.rawValue)\""
            + " vim.g.scwrote_dark_colors = \"\(colors.dark.rawValue)\""
            + " vim.api.nvim_create_autocmd(\"VimEnter\", { once = true, callback = function()"
            + " if not (\",\" .. vim.o.runtimepath .. \",\"):find(\",\" .. folder .. \",\", 1, true)"
            + " then vim.opt.runtimepath:append(folder) end end })"
        let words = [
            nvimPath, "--listen", listenAddress,
            "--cmd", setup,
            "--cmd", "set background=\(colors.background.rawValue)",
            "--cmd", "colorscheme scwrote",
        ]
        return (words + nvimArguments).map(Self.singleQuoted).joined(separator: " ")
    }

    private static func absolute(_ path: String, from directory: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
            .standardizedFileURL.path
    }

    private static func singleQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What nvim starts with to come up in scwrote's colorscheme.
public struct LaunchColors: Equatable, Sendable {
    /// The background the appearance mode asks for.
    public var background: NvimBackground
    public var light: LightColors
    public var dark: DarkColors
    /// The folder holding `colors/scwrote.lua`, added to nvim's `runtimepath`.
    public var runtimeFolder: String

    public init(background: NvimBackground, light: LightColors, dark: DarkColors, runtimeFolder: String) {
        self.background = background
        self.light = light
        self.dark = dark
        self.runtimeFolder = runtimeFolder
    }
}
