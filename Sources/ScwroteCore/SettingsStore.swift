import Foundation
import Observation

/// The settings as this process applies them: loaded from the file, changed at
/// once by `set` (then written), and kept in step with the file as other
/// writers change it.
@MainActor @Observable
public final class SettingsStore {
    public let file: SettingsFile
    public private(set) var settings: Settings
    /// The parser's message while the file can't be read, else nil.
    public private(set) var problem: String?

    @ObservationIgnored private var handlers: [@MainActor (Settings) -> Void] = []
    @ObservationIgnored private var watcher: FolderWatcher?
    /// What `watcher` watches (a real path), if anything.
    @ObservationIgnored private(set) var watchedRoot: String?

    public init(file: SettingsFile) {
        self.file = file
        settings = .defaults
        switch file.load() {
        case .missing: break
        case .loaded(let loaded): settings = loaded
        case .unreadable(let message):
            problem = message
            Self.log("couldn't read \(file.path): \(message)")
        }
    }

    /// Re-reads the file. An unreadable file keeps the values as they were.
    public func reload() {
        switch file.load() {
        case .missing:
            problem = nil
            apply(.defaults)
        case .loaded(let loaded):
            problem = nil
            apply(loaded)
        case .unreadable(let message):
            if problem != message { Self.log("couldn't read \(file.path): \(message)") }
            problem = message
        }
    }

    /// Applies the change at once, then writes it. False if the write failed;
    /// the value stays changed in this process.
    @discardableResult
    public func set(_ key: SettingKey, _ value: Bool) -> Bool {
        var changed = settings
        key.set(value, in: &changed)
        return apply(changed) { try file.write(key, value) }
    }

    /// Like `set(_:_:)`, for the appearance mode.
    @discardableResult
    public func set(_ mode: AppearanceMode) -> Bool {
        var changed = settings
        changed.appearanceMode = mode
        return apply(changed) { try file.write(mode) }
    }

    /// Like `set(_:_:)`, for the light colors.
    @discardableResult
    public func set(_ colors: LightColors) -> Bool {
        var changed = settings
        changed.lightColors = colors
        return apply(changed) { try file.write(colors) }
    }

    /// Like `set(_:_:)`, for the dark colors.
    @discardableResult
    public func set(_ colors: DarkColors) -> Bool {
        var changed = settings
        changed.darkColors = colors
        return apply(changed) { try file.write(colors) }
    }

    private func apply(_ new: Settings, writing write: () throws -> Void) -> Bool {
        apply(new)
        do {
            try write()
            return true
        } catch {
            let reason = (error as? SettingsFileUnreadable)?.message ?? error.localizedDescription
            Self.log("couldn't write \(file.path): \(reason)")
            return false
        }
    }

    /// Runs `handler` after `settings` changes, in this process or by the file.
    public func onChange(_ handler: @escaping @MainActor (Settings) -> Void) {
        handlers.append(handler)
    }

    /// The settings file's folder if it exists, else its nearest existing ancestor.
    public static func watchRoot(for settingsPath: String, exists: (String) -> Bool) -> String {
        var folder = (settingsPath as NSString).deletingLastPathComponent
        while !folder.isEmpty, folder != "/", !exists(folder) {
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folder.isEmpty ? "/" : folder
    }

    /// The real folder to watch now: where the file really lives (through a
    /// symlinked file or folder), or, while it doesn't exist, the settings
    /// folder or its nearest existing ancestor.
    private func expectedRoot() -> String {
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let target = exists(file.path) ? URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path : file.path
        let root = Self.watchRoot(for: target, exists: exists)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    /// Follows the file: on each change near it, reloads. Watches the folder
    /// the file really lives in, or while that doesn't exist, its nearest
    /// existing ancestor.
    public func startWatching() {
        stopWatching()
        let real = expectedRoot()
        watchedRoot = real
        watcher = FolderWatcher(path: real) { [weak self] in self?.fileChanged() }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedRoot = nil
    }

    private func fileChanged() {
        reload()
        guard watcher != nil else { return }
        let watched = watchedRoot
        if expectedRoot() != watched || !FileManager.default.fileExists(atPath: watched ?? "") {
            // Not inside the watcher's own callback: that would free it mid-call.
            DispatchQueue.main.async { [weak self] in
                guard let self, watcher != nil, watchedRoot == watched else { return }
                startWatching()
                reload()
            }
        }
    }

    private func apply(_ new: Settings) {
        guard new != settings else { return }
        settings = new
        for handler in handlers { handler(new) }
    }

    private nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data("scwrote: \(line)\n".utf8))
    }
}
