/// A color in sRGB, components in 0...1.
public struct RGBColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 0xRRGGBB, as `nvim_get_hl` gives colors.
    public init(rgb: Int) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// This color mixed into `background`: `amount` of this, the rest of
    /// `background`, component by component in sRGB.
    public func blended(into background: RGBColor, _ amount: Double) -> RGBColor {
        RGBColor(
            red: background.red + (red - background.red) * amount,
            green: background.green + (green - background.green) * amount,
            blue: background.blue + (blue - background.blue) * amount)
    }

    /// Whether it reads as dark (see `BackgroundTone`).
    public var isDark: Bool { BackgroundTone.isDark(red: red, green: green, blue: blue) }
}
