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
        } catch { return .unreadable(message: Self.problem(error)) }
        var settings = Settings.defaults
        for key in SettingKey.allCases {
            if let value = Self.bool(in: object, at: key.path) { key.set(value, in: &settings) }
        }
        if let raw = Self.string(in: object, at: Self.modePath), let mode = AppearanceMode(rawValue: raw) {
            settings.appearanceMode = mode
        }
        if let raw = Self.string(in: object, at: Self.lightColorsPath), let colors = LightColors(rawValue: raw) {
            settings.lightColors = colors
        }
        if let raw = Self.string(in: object, at: Self.darkColorsPath), let colors = DarkColors(rawValue: raw) {
            settings.darkColors = colors
        }
        return .loaded(settings)
    }

    /// Sets one key, keeping every other key and value as found, and replaces
    /// the file atomically (through a symlink, the file it points to). Creates
    /// the folder and file if missing. Throws `SettingsFileUnreadable` without
    /// touching the file if it doesn't parse.
    public func write(_ key: SettingKey, _ value: Bool) throws {
        try write(value, at: key.path)
    }

    /// Sets the appearance mode, with the same guarantees as the other write.
    public func write(_ mode: AppearanceMode) throws {
        try write(mode.rawValue, at: Self.modePath)
    }

    /// Sets the light colors, with the same guarantees as the other write.
    public func write(_ colors: LightColors) throws {
        try write(colors.rawValue, at: Self.lightColorsPath)
    }

    /// Sets the dark colors, with the same guarantees as the other write.
    public func write(_ colors: DarkColors) throws {
        try write(colors.rawValue, at: Self.darkColorsPath)
    }

    private static let lightColorsPath = ["appearance", "lightColors"]
    private static let darkColorsPath = ["appearance", "darkColors"]

    /// Where the appearance mode lives in the file.
    private static let modePath = ["appearance", "mode"]

    private func write(_ value: Any, at path: [String]) throws {
        let real = destination()
        var object = FileManager.default.fileExists(atPath: real) ? try Self.readObject(at: real) : [:]
        let section = path[0]
        var values = object[section] as? [String: Any] ?? [:]
        values[path[1]] = value
        object[section] = values
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        let folder = (real as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temp = folder + "/.settings-" + UUID().uuidString + ".tmp"
        try data.write(to: URL(fileURLWithPath: temp))
        if let mode = try? FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp)
        }
        if rename(temp, real) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The parser's own message (with its line and column) when it has one.
    private static func problem(_ error: Error) -> String {
        (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
    }

    /// The file a write lands in: `path` followed through symlinks, including
    /// ones whose target doesn't exist yet.
    private func destination() -> String {
        var current = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for _ in 0..<32 {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            let folder = (current as NSString).deletingLastPathComponent
            let next = link.hasPrefix("/") ? link : folder + "/" + link
            current = URL(fileURLWithPath: next).resolvingSymlinksInPath().path
        }
        return current
    }

    private static func readObject(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch {
            throw SettingsFileUnreadable(message: Self.problem(error))
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

    /// The value at `path` if it is a JSON string.
    private static func string(in object: [String: Any], at path: [String]) -> String? {
        guard let section = object[path[0]] as? [String: Any] else { return nil }
        return section[path[1]] as? String
    }
}
