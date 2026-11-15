/// Whether a theme reads as dark, from its background color: what decides the
/// window's appearance (title bar text, scrollers) and mermaid's dark mode, so
/// system-drawn parts match the theme rather than the system's light or dark
/// setting.
public enum BackgroundTone {
    /// sRGB components in 0...1. Brightness weighted the way the eye sees it
    /// (Rec. 709 luma: green most, blue least); below half is dark.
    public static func isDark(red: Double, green: Double, blue: Double) -> Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
    }
}
