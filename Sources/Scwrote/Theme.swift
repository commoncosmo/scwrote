import AppKit
import GhosttyKit
import ScwroteCore

/// Colors and font for what scwrote draws itself (the file browser and the
/// preview pane): nvim's colors where it reported them, else those of the
/// Ghostty config the terminal uses, so all panes match.
struct Theme: Equatable {
    var background: NSColor
    var foreground: NSColor
    /// Headers and other secondary text.
    var dim: NSColor
    /// Behind text drawn in `foreground`: the prompt's cursor, the overlays'
    /// query highlight, the preview's cursor rows and diagram boxes.
    var selection: NSColor
    /// The browser's cursor row while it has the keyboard, and the overlays'
    /// selected row: nvim's `Visual`.
    var visual: NSColor
    /// Text on a `visual` row.
    var visualText: NSColor
    /// The cursor row while the editor has the keyboard.
    var selectionInactive: NSColor
    var folder: NSColor
    /// Folders on the browser's `visual` row, and matches on the overlays':
    /// `visualText` when nvim's `Visual` sets a text color, else `folder`.
    var selectedFolder: NSColor
    /// Secondary text on the overlays' `visual` row, by the same rule:
    /// `visualText` when `Visual` sets a text color, else `dim`.
    var selectedDim: NSColor
    /// Unsaved changes and errors in the preview's header.
    var warning: NSColor
    var divider: NSColor
    /// The file browser's shade, its secondary text, and its cursor row while
    /// the editor has the keyboard (see `ThemeColors`).
    var browserBackground: NSColor
    var browserDim: NSColor
    var browserSelectionInactive: NSColor
    var font: NSFont
    /// Space above the terminal's first line (`window-padding-y`), so the
    /// browser's rows can start level with nvim's.
    var topPadding: CGFloat

    init(colors: ThemeColors, font: NSFont, topPadding: CGFloat) {
        background = Self.nsColor(colors.background)
        foreground = Self.nsColor(colors.foreground)
        dim = Self.nsColor(colors.dim)
        selection = Self.nsColor(colors.selection)
        visual = Self.nsColor(colors.visual)
        visualText = Self.nsColor(colors.visualText)
        selectionInactive = Self.nsColor(colors.selectionInactive)
        folder = colors.folder.map(Self.nsColor) ?? .systemBlue
        let visualSetsText = colors.visualText != colors.foreground
        selectedFolder = visualSetsText ? visualText : folder
        selectedDim = visualSetsText ? visualText : dim
        warning = colors.warning.map(Self.nsColor) ?? .systemYellow
        divider = Self.nsColor(colors.divider)
        browserBackground = Self.nsColor(colors.browserBackground)
        browserDim = Self.nsColor(colors.browserDim)
        browserSelectionInactive = Self.nsColor(colors.browserSelectionInactive)
        self.font = font
        self.topPadding = topPadding
    }

    /// Whether the background reads as dark (see `BackgroundTone`).
    var isDark: Bool {
        let background = background.usingColorSpace(.sRGB) ?? background
        return BackgroundTone.isDark(
            red: background.redComponent, green: background.greenComponent, blue: background.blueComponent)
    }

    /// The window's appearance for this theme. The title bar takes the theme's
    /// background, so its text and controls must follow the theme too, not
    /// the system: a dark theme in light mode would get dark title text.
    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Colors compared in sRGB, the font by name and size: a theme rebuilt
    /// from the same colors is equal, so it needn't be applied again.
    static func == (lhs: Theme, rhs: Theme) -> Bool {
        let colors: [KeyPath<Theme, NSColor>] = [
            \.background, \.foreground, \.dim, \.selection, \.visual, \.visualText, \.selectionInactive,
            \.folder, \.selectedFolder, \.selectedDim, \.warning, \.divider,
            \.browserBackground, \.browserDim, \.browserSelectionInactive,
        ]
        return colors.allSatisfy { sRGB(lhs[keyPath: $0]) == sRGB(rhs[keyPath: $0]) }
            && lhs.font.fontName == rhs.font.fontName && lhs.font.pointSize == rhs.font.pointSize
            && lhs.topPadding == rhs.topPadding
    }

    /// What the theme takes from the Ghostty config: its final colors (theme
    /// applied, read through libghostty), font and top padding. Call after a
    /// TerminalController exists: creating one initializes libghostty.
    static func loadGhostty(configContents: String) -> (ghostty: GhosttyColors, font: NSFont, topPadding: CGFloat) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("scwrote-theme-\(UUID().uuidString).conf")
        try? configContents.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)

        var palette = ghostty_config_palette_s()
        let hasPalette = get(config, "palette", &palette)
        func paletteColor(_ index: Int) -> ScwroteCore.RGBColor? {
            guard hasPalette else { return nil }
            return withUnsafeBytes(of: palette.colors) { raw in
                rgbColor(raw.bindMemory(to: ghostty_config_color_s.self)[index])
            }
        }

        var fontSize: Float = 13
        _ = get(config, "font-size", &fontSize)

        let ghostty = GhosttyColors(
            background: color(config, "background"),
            foreground: color(config, "foreground"),
            selectionBackground: color(config, "selection-background"),
            palette3: paletteColor(3),
            palette4: paletteColor(4)
        )
        return (
            ghostty: ghostty,
            font: font(family: primaryFontFamily(in: configContents), size: CGFloat(fontSize)),
            topPadding: CGFloat(GhosttyConfig.topPadding(in: configContents))
        )
    }

    /// A CSS color, `#rrggbb` in sRGB, for the preview's renderer page.
    static func css(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }

    /// The first `font-family`, as Ghostty reads it: an empty value clears the
    /// list, later lines add fallbacks.
    private static func primaryFontFamily(in config: String) -> String? {
        var families: [String] = []
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "font-family" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.isEmpty { families.removeAll() } else { families.append(value) }
        }
        return families.first
    }

    /// The user's font, else JetBrains Mono (Ghostty's default, if installed),
    /// else the system monospaced font.
    private static func font(family: String?, size: CGFloat) -> NSFont {
        for candidate in [family, "JetBrains Mono"].compactMap({ $0 }) {
            if let font = NSFontManager.shared.font(withFamily: candidate, traits: [], weight: 5, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// libghostty writes the value's raw bytes, so only plain-data types.
    private static func get<T: BitwiseCopyable>(_ config: ghostty_config_t?, _ key: String, _ value: inout T) -> Bool {
        ghostty_config_get(config, &value, key, UInt(key.utf8.count))
    }

    private static func color(_ config: ghostty_config_t?, _ key: String) -> ScwroteCore.RGBColor? {
        var value = ghostty_config_color_s()
        return get(config, key, &value) ? rgbColor(value) : nil
    }

    private static func rgbColor(_ color: ghostty_config_color_s) -> ScwroteCore.RGBColor {
        ScwroteCore.RGBColor(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }

    private static func nsColor(_ color: ScwroteCore.RGBColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    }

    /// A color's components in sRGB, alpha last.
    private static func sRGB(_ color: NSColor) -> [CGFloat] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }
}

/// What a theme takes from the Ghostty config, kept so a theme can be built
/// again when nvim reports new colors.
struct ThemeBase {
    var ghostty: GhosttyColors
    var font: NSFont
    var topPadding: CGFloat

    init(configContents: String) {
        (ghostty, font, topPadding) = Theme.loadGhostty(configContents: configContents)
    }

    /// nvim's colors where `nvim` has them, else the Ghostty config's.
    func theme(nvim: NvimColors?) -> Theme {
        Theme(colors: .resolve(nvim: nvim, ghostty: ghostty), font: font, topPadding: topPadding)
    }
}
