import AppKit
import GhosttyTerminal
import ScreditCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let environment = ProcessInfo.processInfo.environment
        // SCREDIT_DEBUG=1 logs libghostty's lifecycle and actions to
        // ~/Library/Logs/scredit.log (the launcher sends stderr there).
        if environment["SCREDIT_DEBUG"] != nil {
            TerminalDebugLog.enable([.lifecycle, .actions])
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data("ghostty: \(message)\n".utf8))
            }
        }
        guard let nvim = ExecutableLocator.find("nvim", searchPath: environment["PATH"] ?? "") else {
            failToLaunch(
                "Couldn't find nvim on your PATH.",
                detail: "Install it with `brew install neovim`, then run scredit again."
            )
            return
        }

        let request = LaunchRequest.resolve(
            arguments: Array(CommandLine.arguments.dropFirst()),
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        let controller: TerminalController
        do {
            controller = try makeTerminalController(
                command: request.shellCommand(nvimPath: nvim),
                environment: environment
            )
        } catch {
            failToLaunch(
                "Can't open a path that contains a line break.",
                detail: "Rename it, or open it from inside nvim with :e."
            )
            return
        }
        let editor = EditorWindowController(request: request, controller: controller)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Quitting hangs up on every nvim, so ask first if any are still running.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard editors.contains(where: \.isNvimRunning) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit scredit?"
        alert.informativeText = "nvim is still running. Any unsaved changes will be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Uses the user's own Ghostty config so the window looks like their Ghostty,
    /// plus the nvim command for this window.
    private func makeTerminalController(command: String, environment: [String: String]) throws -> TerminalController {
        let home = NSHomeDirectory()
        let xdg = environment["XDG_CONFIG_HOME"]
        let userConfig = GhosttyConfig.load(
            home: home,
            xdgConfigHome: xdg,
            themeDirectories: GhosttyConfig.themeDirectories(home: home, xdgConfigHome: xdg)
        )
        let config = try GhosttyConfig.editorConfig(userConfig: userConfig, command: command)
        // An empty theme: the library's default (Alabaster/Afterglow, picked by
        // the system appearance) would otherwise be layered over the user's own.
        let controller = TerminalController(configSource: .generated(config), theme: TerminalTheme())
        if environment["SCREDIT_DEBUG"] != nil {
            let bg = controller.backgroundColor
            FileHandle.standardError.write(Data("scredit: background=\(bg.red),\(bg.green),\(bg.blue)\n".utf8))
        }
        return controller
    }

    private func failToLaunch(_ message: String, detail: String) {
        FileHandle.standardError.write(Data("scredit: \(message) \(detail)\n".utf8))
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        NSApp.terminate(nil)
    }
}
