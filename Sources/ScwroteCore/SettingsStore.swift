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
    @ObservationIgnored private var watchedRoot: String?

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
        apply(changed)
        do {
            try file.write(key, value)
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

    /// Follows the file: on each change in its folder (or, while the folder
    /// doesn't exist yet, in its nearest existing ancestor), reloads.
    public func startWatching() {
        stopWatching()
        let root = Self.watchRoot(for: file.path) { FileManager.default.fileExists(atPath: $0) }
        let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        watchedRoot = real
        watcher = FolderWatcher(path: real) { [weak self] in self?.fileChanged() }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedRoot = nil
    }

    private func fileChanged() {
        if watcher != nil {
            let folder = (file.path as NSString).deletingLastPathComponent
            let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            var isFolder: ObjCBool = false
            if real != watchedRoot, FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue {
                startWatching()
            }
        }
        reload()
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
