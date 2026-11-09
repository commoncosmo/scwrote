import AppKit
import GhosttyKit
import ScreditCore

/// Colors and font for what scredit draws itself (the file browser), taken
/// from the same Ghostty config the terminal uses so both panes match.
struct Theme {
    var background: NSColor
    var foreground: NSColor
    /// Headers and other secondary text.
    var dim: NSColor
    /// The cursor row while the browser has the keyboard.
    var selection: NSColor
    /// The cursor row while the editor has the keyboard.
    var selectionInactive: NSColor
    var folder: NSColor
    var divider: NSColor
    var font: NSFont
    /// Space above the terminal's first line (`window-padding-y`), so the
    /// browser's rows can start level with nvim's.
    var topPadding: CGFloat

    /// Reads the final colors (theme applied) through libghostty. Call after a
    /// TerminalController exists: creating one initializes libghostty.
    static func load(configContents: String) -> Theme {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("scredit-theme-\(UUID().uuidString).conf")
        try? configContents.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)

        let background = color(config, "background") ?? NSColor(white: 0.13, alpha: 1)
        let foreground = color(config, "foreground") ?? NSColor(white: 0.85, alpha: 1)
        var palette = ghostty_config_palette_s()
        let hasPalette = get(config, "palette", &palette)
        let blue = hasPalette ? withUnsafeBytes(of: palette.colors) { raw in
            nsColor(raw.bindMemory(to: ghostty_config_color_s.self)[4])
        } : NSColor.systemBlue

        var fontSize: Float = 13
        _ = get(config, "font-size", &fontSize)

        return Theme(
            background: background,
            foreground: foreground,
            dim: blend(foreground, into: background, 0.5),
            selection: color(config, "selection-background") ?? blend(foreground, into: background, 0.22),
            selectionInactive: blend(foreground, into: background, 0.1),
            folder: blue,
            divider: blend(foreground, into: background, 0.15),
            font: font(family: primaryFontFamily(in: configContents), size: CGFloat(fontSize)),
            topPadding: CGFloat(GhosttyConfig.topPadding(in: configContents))
        )
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

    private static func color(_ config: ghostty_config_t?, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        return get(config, key, &value) ? nsColor(value) : nil
    }

    private static func nsColor(_ color: ghostty_config_color_s) -> NSColor {
        NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    private static func blend(_ top: NSColor, into base: NSColor, _ amount: CGFloat) -> NSColor {
        base.blended(withFraction: amount, of: top) ?? base
    }
}
