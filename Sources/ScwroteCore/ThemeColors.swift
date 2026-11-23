/// What `Theme.load` reads from the Ghostty config.
public struct GhosttyColors: Equatable, Sendable {
    public var background: RGBColor?
    public var foreground: RGBColor?
    public var selectionBackground: RGBColor?
    public var palette3: RGBColor?
    public var palette4: RGBColor?

    public init(
        background: RGBColor? = nil, foreground: RGBColor? = nil, selectionBackground: RGBColor? = nil,
        palette3: RGBColor? = nil, palette4: RGBColor? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.selectionBackground = selectionBackground
        self.palette3 = palette3
        self.palette4 = palette4
    }
}

/// The colors scwrote draws its own panes with: nvim's where it reports them,
/// else Ghostty's, else what scwrote has always used.
public struct ThemeColors: Equatable, Sendable {
    public var background: RGBColor
    public var foreground: RGBColor
    /// Headers and other secondary text.
    public var dim: RGBColor
    /// The cursor row while the browser has the keyboard.
    public var selection: RGBColor
    /// Text on the selected row.
    public var selectionText: RGBColor
    /// The cursor row while the editor has the keyboard.
    public var selectionInactive: RGBColor
    public var divider: RGBColor
    /// nil: the system blue.
    public var folder: RGBColor?
    /// nil: the system yellow.
    public var warning: RGBColor?

    /// With no nvim report this is what `Theme.load` has always produced.
    public static func resolve(nvim: NvimColors?, ghostty: GhosttyColors) -> ThemeColors {
        let normal = nvim?.groups["Normal"]
        // A transparent Normal (no bg) takes Ghostty's background and
        // foreground as a pair.
        let nvimPair = normal?.bg != nil
        let background = (nvimPair ? normal?.bg : nil) ?? ghostty.background ?? RGBColor(red: 0.13, green: 0.13, blue: 0.13)
        let foreground =
            (nvimPair ? normal?.fg : nil) ?? ghostty.foreground ?? RGBColor(red: 0.85, green: 0.85, blue: 0.85)
        func fg(_ name: String) -> RGBColor? { nvim?.groups[name]?.fg }

        let blendedSelection = foreground.blended(into: background, 0.22)
        let selection: RGBColor
        if let nvim {
            selection = nvim.groups["Visual"]?.bg ?? blendedSelection
        } else {
            selection = ghostty.selectionBackground ?? blendedSelection
        }
        return ThemeColors(
            background: background,
            foreground: foreground,
            dim: foreground.blended(into: background, 0.5),
            selection: selection,
            selectionText: fg("Visual") ?? foreground,
            selectionInactive: foreground.blended(into: background, 0.1),
            divider: fg("WinSeparator") ?? fg("VertSplit") ?? foreground.blended(into: background, 0.15),
            folder: fg("Directory") ?? ghostty.palette4,
            warning: fg("WarningMsg") ?? fg("DiagnosticWarn") ?? ghostty.palette3)
    }
}
