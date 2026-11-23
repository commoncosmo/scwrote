/// The user's preferences, as scwrote applies them.
public struct Settings: Equatable, Sendable {
    /// Whether quick open lists hidden files and folders.
    public var showsHiddenFilesInQuickOpen: Bool
    /// Whether launching in a folder restores that folder's saved session.
    public var reopensFolders: Bool

    public init(showsHiddenFilesInQuickOpen: Bool, reopensFolders: Bool) {
        self.showsHiddenFilesInQuickOpen = showsHiddenFilesInQuickOpen
        self.reopensFolders = reopensFolders
    }

    /// What applies when there is no file, or a value in it is missing or of the wrong type.
    public static let defaults = Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: true)
}

/// One setting, with where its value lives in settings.json.
public enum SettingKey: CaseIterable, Sendable {
    case showsHiddenFilesInQuickOpen
    case reopensFolders

    /// The keys leading to the value: a section name, then the setting's name.
    public var path: [String] {
        switch self {
        case .showsHiddenFilesInQuickOpen: ["quickOpen", "showHiddenFiles"]
        case .reopensFolders: ["folders", "reopen"]
        }
    }

    public func value(in settings: Settings) -> Bool {
        switch self {
        case .showsHiddenFilesInQuickOpen: settings.showsHiddenFilesInQuickOpen
        case .reopensFolders: settings.reopensFolders
        }
    }

    public func set(_ value: Bool, in settings: inout Settings) {
        switch self {
        case .showsHiddenFilesInQuickOpen: settings.showsHiddenFilesInQuickOpen = value
        case .reopensFolders: settings.reopensFolders = value
        }
    }
}

/// What reading settings.json found.
public enum SettingsLoad: Equatable, Sendable {
    /// There is no file.
    case missing
    /// The file parsed; values that were missing or of the wrong type are their defaults.
    case loaded(Settings)
    /// The file exists but isn't a JSON object; `message` says why.
    case unreadable(message: String)
}
