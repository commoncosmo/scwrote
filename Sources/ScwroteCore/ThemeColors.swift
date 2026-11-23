/// What `Theme.loadGhostty` reads from the Ghostty config.
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
    /// Behind text drawn in `foreground`: the prompt's cursor, the overlays'
    /// query highlight, the preview's cursor rows and diagram boxes.
    public var selection: RGBColor
    /// The browser's cursor row while it has the keyboard, and the overlays'
    /// selected row: `Visual`'s background as nvim draws it.
    public var visual: RGBColor
    /// Text on a `visual` row: `Visual`'s text as nvim draws it.
    public var visualText: RGBColor
    /// The cursor row while the editor has the keyboard.
    public var selectionInactive: RGBColor
    public var divider: RGBColor
    /// nil: the system blue.
    public var folder: RGBColor?
    /// nil: the system yellow.
    public var warning: RGBColor?

    /// With no nvim report these are the Ghostty config's colors, as scwrote
    /// drew before it took nvim's.
    public static func resolve(nvim: NvimColors?, ghostty: GhosttyColors) -> ThemeColors {
        let normal = nvim?.groups["Normal"]
        // A transparent Normal (no bg) takes Ghostty's background and
        // foreground as a pair.
        let nvimPair = normal?.bg != nil
        let background = (nvimPair ? normal?.bg : nil) ?? ghostty.background ?? RGBColor(red: 0.13, green: 0.13, blue: 0.13)
        let foreground =
            (nvimPair ? normal?.fg : nil) ?? ghostty.foreground ?? RGBColor(red: 0.85, green: 0.85, blue: 0.85)
        /// A group's colors as nvim draws them: a `reverse` group's swapped,
        /// a missing one taken from Normal in use.
        func drawn(_ name: String) -> (fg: RGBColor?, bg: RGBColor?) {
            guard let group = nvim?.groups[name] else { return (nil, nil) }
            guard group.reverse else { return (group.fg, group.bg) }
            return (group.bg ?? background, group.fg ?? foreground)
        }
        func fg(_ name: String) -> RGBColor? { drawn(name).fg }

        let blendedSelection = foreground.blended(into: background, 0.22)
        let selection = nvim == nil ? ghostty.selectionBackground ?? blendedSelection : blendedSelection
        let visual = drawn("Visual")
        return ThemeColors(
            background: background,
            foreground: foreground,
            dim: foreground.blended(into: background, 0.5),
            selection: selection,
            visual: visual.bg ?? selection,
            visualText: visual.fg ?? foreground,
            selectionInactive: foreground.blended(into: background, 0.1),
            divider: fg("WinSeparator") ?? fg("VertSplit") ?? foreground.blended(into: background, 0.15),
            folder: fg("Directory") ?? ghostty.palette4,
            warning: fg("WarningMsg") ?? fg("DiagnosticWarn") ?? ghostty.palette3)
    }
}
