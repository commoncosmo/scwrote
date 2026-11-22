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

    public init(
        workingDirectory: String,
        nvimArguments: [String],
        title: String,
        browserRoot: String,
        startsInBrowser: Bool,
        restoresSession: Bool = true,
        namedFiles: [String] = []
    ) {
        self.workingDirectory = workingDirectory
        self.nvimArguments = nvimArguments
        self.title = title
        self.browserRoot = browserRoot
        self.startsInBrowser = startsInBrowser
        self.restoresSession = restoresSession
        self.namedFiles = namedFiles
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
                restoresSession: restoresSession
            )
        }
        return LaunchRequest(
            workingDirectory: currentDirectory,
            nvimArguments: arguments,
            title: URL(fileURLWithPath: paths.first ?? currentDirectory).lastPathComponent,
            browserRoot: currentDirectory,
            startsInBrowser: false,
            restoresSession: restoresSession,
            namedFiles: paths.map { absolute($0, from: currentDirectory) }
        )
    }

    /// The command Ghostty runs. nvim listens on `listenAddress` so scwrote can
    /// talk to it. Ghostty hands the command to a shell, so every word is
    /// single-quoted to keep spaces and quotes in paths intact.
    public func shellCommand(nvimPath: String, listenAddress: String) -> String {
        ([nvimPath, "--listen", listenAddress] + nvimArguments)
            .map(Self.singleQuoted)
            .joined(separator: " ")
    }

    private static func absolute(_ path: String, from directory: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
            .standardizedFileURL.path
    }

    private static func singleQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
