import Foundation

/// What `scredit <args>` asked for, turned into what the window should run.
public struct LaunchRequest: Equatable, Sendable {
    /// Folder nvim starts in.
    public var workingDirectory: String
    /// Arguments handed to nvim.
    public var nvimArguments: [String]
    /// Window title until nvim sets its own.
    public var title: String

    public init(workingDirectory: String, nvimArguments: [String], title: String) {
        self.workingDirectory = workingDirectory
        self.nvimArguments = nvimArguments
        self.title = title
    }

    /// Arguments go to nvim exactly as typed, and nvim starts in the shell's
    /// folder, so `scredit <args>` behaves like `nvim <args>` in that shell.
    public static func resolve(arguments: [String], currentDirectory: String) -> LaunchRequest {
        let firstPath = arguments.first { !$0.hasPrefix("+") && !$0.hasPrefix("-") }
        // DECISION (open): `scredit ./source/testrepo` keeps the shell's folder
        // as nvim's working directory, matching `nvim ./source/testrepo`.
        // The alternative is to make that folder the working directory, like
        // `code ./testrepo` opening a project, which would also set the
        // "codebase" the AI features read later.
        let title = URL(fileURLWithPath: firstPath ?? currentDirectory).lastPathComponent
        return LaunchRequest(
            workingDirectory: currentDirectory,
            nvimArguments: arguments,
            title: title
        )
    }

    /// The command Ghostty runs. Ghostty hands a command string to a shell, so
    /// every word is single-quoted to keep spaces and quotes in paths intact.
    public func shellCommand(nvimPath: String) -> String {
        ([nvimPath] + nvimArguments).map(Self.singleQuoted).joined(separator: " ")
    }

    private static func singleQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
