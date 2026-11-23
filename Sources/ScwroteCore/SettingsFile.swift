import Foundation

/// Thrown by a write when the existing file doesn't parse as a JSON object,
/// so the file is left as it is.
public struct SettingsFileUnreadable: Error {
    public let message: String
    public init(message: String) { self.message = message }
}

/// The settings.json file: read as it is now, and changed one key at a time.
public struct SettingsFile: Sendable {
    public let path: String

    /// `SCWROTE_SETTINGS` if set, else `$XDG_CONFIG_HOME/scwrote/settings.json`,
    /// else `~/.config/scwrote/settings.json`.
    public init(environment: [String: String], home: String) {
        if let override = environment["SCWROTE_SETTINGS"] {
            path = override
        } else {
            path = (environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/scwrote/settings.json"
        }
    }

    public init(path: String) { self.path = path }

    /// `path` with a leading home folder shown as `~`.
    public static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The settings in the file now. Never throws: a file that can't be read
    /// is reported as `.unreadable`.
    public func load() -> SettingsLoad {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let object: [String: Any]
        do { object = try Self.readObject(at: path) } catch let error as SettingsFileUnreadable {
            return .unreadable(message: error.message)
        } catch { return .unreadable(message: error.localizedDescription) }
        var settings = Settings.defaults
        for key in SettingKey.allCases {
            if let value = Self.bool(in: object, at: key.path) { key.set(value, in: &settings) }
        }
        return .loaded(settings)
    }

    /// Sets one key, keeping every other key and value as found, and replaces
    /// the file atomically (through a symlink, the file it points to). Creates
    /// the folder and file if missing. Throws `SettingsFileUnreadable` without
    /// touching the file if it doesn't parse.
    public func write(_ key: SettingKey, _ value: Bool) throws {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var object = FileManager.default.fileExists(atPath: real) ? try Self.readObject(at: real) : [:]
        let section = key.path[0]
        var values = object[section] as? [String: Any] ?? [:]
        values[key.path[1]] = value
        object[section] = values
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])

        let folder = (real as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temp = folder + "/.settings-" + UUID().uuidString + ".tmp"
        try data.write(to: URL(fileURLWithPath: temp))
        if rename(temp, real) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func readObject(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch {
            throw SettingsFileUnreadable(message: error.localizedDescription)
        }
        guard let object = parsed as? [String: Any] else {
            throw SettingsFileUnreadable(message: "the top level isn't an object")
        }
        return object
    }

    /// The value at `path` if it is a JSON boolean (not a number).
    private static func bool(in object: [String: Any], at path: [String]) -> Bool? {
        guard let section = object[path[0]] as? [String: Any],
            let value = section[path[1]] as? NSNumber,
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value.boolValue
    }
}
