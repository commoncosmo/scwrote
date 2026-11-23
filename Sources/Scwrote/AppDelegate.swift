import AppKit
import GhosttyTerminal
import ScwroteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editors: [EditorWindowController] = []
    /// Made first thing at launch, and shared by the Settings window and the editor.
    private(set) lazy var settingsStore = SettingsStore(
        file: SettingsFile(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    )
    /// Made the first time Settings opens.
    private var settingsWindow: SettingsWindowController?
    /// The `scwrote` launcher waiting to hear that this app is in front.
    private var launcherToNotify: pid_t?

    func applicationDidFinishLaunching(_: Notification) {
        settingsStore.startWatching()
        NSApp.mainMenu = MainMenu.make()

        let environment = ProcessInfo.processInfo.environment
        launcherToNotify = LauncherHandoff.pidToNotify(
            environmentValue: environment[LauncherHandoff.environmentKey],
            parentPID: getppid()
        )
        // Keep it out of nvim's environment, and of anything nvim starts.
        unsetenv(LauncherHandoff.environmentKey)

        // SCWROTE_DEBUG=1 logs libghostty's lifecycle and actions to
        // ~/Library/Logs/scwrote.log (the launcher sends stderr there).
        if environment["SCWROTE_DEBUG"] != nil {
            TerminalDebugLog.enable([.lifecycle, .actions])
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data("ghostty: \(message)\n".utf8))
            }
        }
        guard let nvim = ExecutableLocator.find("nvim", searchPath: environment["PATH"] ?? "") else {
            failToLaunch(
                "Couldn't find nvim on your PATH.",
                detail: "Install it with `brew install neovim`, then run scwrote again."
            )
            return
        }

        let request = LaunchRequest.resolve(
            arguments: Array(CommandLine.arguments.dropFirst()),
            currentDirectory: FileManager.default.currentDirectoryPath,
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
        // nvim listens here so the file browser can tell it what to open.
        let nvimSocket = NSTemporaryDirectory() + "scwrote-\(getpid()).sock"
        let controller: TerminalController
        let config: String
        do {
            (controller, config) = try makeTerminalController(
                command: request.shellCommand(nvimPath: nvim, listenAddress: nvimSocket),
                environment: environment
            )
        } catch {
            failToLaunch(
                "Can't open a path that contains a line break.",
                detail: "Rename it, or open it from inside nvim with :e."
            )
            return
        }
        // The session folder is keyed by the folder nvim starts in: the
        // folder for a folder launch, the shell's for a file launch.
        let sessions = SessionStore(environment: environment, home: NSHomeDirectory())
        let editor = EditorWindowController(
            request: request,
            session: sessions.folder(for: request.workingDirectory),
            controller: controller,
            nvimSocket: nvimSocket,
            theme: Theme.load(configContents: config),
            settingsStore: settingsStore
        )
        // The Settings window never outlives the editor: closing it too lets
        // the app quit after its last window.
        editor.onClose = { [weak self, weak editor] in
            guard let self else { return }
            editors.removeAll { $0 === editor }
            if editors.isEmpty { settingsWindow?.close() }
        }
        editors.append(editor)
        editor.showWindow(nil)
        NSApp.activate()
    }

    /// Settings… in the scwrote menu, and Cmd+, from the editor window: shows
    /// the Settings window, or brings it to the front.
    @objc func showSettings(_: Any?) {
        let settings = settingsWindow ?? SettingsWindowController(store: settingsStore)
        settingsWindow = settings
        settings.show()
    }

    /// We're in front: the launcher can exit and give the shell its prompt back.
    func applicationDidBecomeActive(_: Notification) {
        guard let launcher = launcherToNotify else { return }
        launcherToNotify = nil
        kill(launcher, SIGUSR1)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Quitting hangs up on every nvim, so ask first if any are still running;
    /// "Quit" has each save nvim's side of its session first (a hang-up may
    /// not run nvim's own save on exit).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let running = editors.filter(\.isNvimRunning)
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit scwrote?"
        alert.informativeText = "nvim is still running. Any unsaved changes will be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            for editor in running { await editor.saveSession() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Windows still open as the app quits don't get `windowWillClose`, so
    /// their side of the session is saved here.
    func applicationWillTerminate(_: Notification) {
        for editor in editors { editor.saveWindowSide() }
    }

    /// Uses the user's own Ghostty config so the window looks like their Ghostty,
    /// plus the nvim command for this window. Returns the config too, for the
    /// file browser's theme.
    private func makeTerminalController(
        command: String,
        environment: [String: String]
    ) throws -> (TerminalController, String) {
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
        if environment["SCWROTE_DEBUG"] != nil {
            let bg = controller.backgroundColor
            FileHandle.standardError.write(Data("scwrote: background=\(bg.red),\(bg.green),\(bg.blue)\n".utf8))
        }
        return (controller, config)
    }

    private func failToLaunch(_ message: String, detail: String) {
        FileHandle.standardError.write(Data("scwrote: \(message) \(detail)\n".utf8))
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        NSApp.terminate(nil)
    }
}
