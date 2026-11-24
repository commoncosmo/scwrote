/// The `background` nvim is told to use.
public enum NvimBackground: String, Sendable {
    case light, dark
}

/// Which appearance the editor uses: the system's, or always light or dark.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark

    /// The `background` this mode asks for, given whether macOS is in dark mode.
    public func background(systemIsDark: Bool) -> NvimBackground {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The colors scwrote uses in light mode when the user's nvim config picks no colorscheme.
public enum LightColors: String, CaseIterable, Sendable {
    case warmPaper, coolSlate
}

/// The colors scwrote uses in dark mode when the user's nvim config picks no colorscheme.
public enum DarkColors: String, CaseIterable, Sendable {
    case softDark, nvimDefault
}

/// The user's preferences, as scwrote applies them.
public struct Settings: Equatable, Sendable {
    /// Whether quick open lists hidden files and folders.
    public var showsHiddenFilesInQuickOpen: Bool
    /// Whether launching in a folder restores that folder's saved session.
    public var reopensFolders: Bool

    /// Whether the editor follows macOS's appearance or stays light or dark.
    public var appearanceMode: AppearanceMode

    /// The colors used in light mode when nvim's config picks none.
    public var lightColors: LightColors
    /// The colors used in dark mode when nvim's config picks none.
    public var darkColors: DarkColors

    public init(
        showsHiddenFilesInQuickOpen: Bool, reopensFolders: Bool, appearanceMode: AppearanceMode = .system,
        lightColors: LightColors = .warmPaper, darkColors: DarkColors = .softDark
    ) {
        self.showsHiddenFilesInQuickOpen = showsHiddenFilesInQuickOpen
        self.reopensFolders = reopensFolders
        self.appearanceMode = appearanceMode
        self.lightColors = lightColors
        self.darkColors = darkColors
    }

    /// What applies when there is no file, or a value in it is missing or of the wrong type.
    public static let defaults = Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: true, appearanceMode: .system)
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
