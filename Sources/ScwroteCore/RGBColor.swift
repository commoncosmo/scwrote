import CoreGraphics

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
    /// `background`. Mixed as `NSColor.blended(withFraction:of:)` mixes, in
    /// Generic RGB, so the theme's blends look as they always have.
    public func blended(into background: RGBColor, _ amount: Double) -> RGBColor {
        guard let top = genericRGB, let base = background.genericRGB else { return background }
        let mixed = zip(base, top).map { $0 + ($1 - $0) * amount }
        return RGBColor(converting: mixed, from: Self.genericRGBSpace) ?? background
    }

    /// Whether it reads as dark (see `BackgroundTone`).
    public var isDark: Bool { BackgroundTone.isDark(red: red, green: green, blue: blue) }

    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// AppKit's `NSColorSpace.genericRGB`. Swift hides the
    /// `CGColorSpace.genericRGB` constant, so it goes by its name.
    private static let genericRGBSpace = CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString)!

    /// Red, green and blue in Generic RGB.
    private var genericRGB: [Double]? {
        let components = [red, green, blue, 1].map { CGFloat($0) }
        guard let color = CGColor(colorSpace: Self.sRGBSpace, components: components),
            let converted = color.converted(to: Self.genericRGBSpace, intent: .defaultIntent, options: nil),
            let parts = converted.components, parts.count >= 3
        else { return nil }
        return parts.prefix(3).map(Double.init)
    }

    /// From red, green and blue in `space`, converted to sRGB.
    private init?(converting components: [Double], from space: CGColorSpace) {
        let values = (components + [1]).map { CGFloat($0) }
        guard let color = CGColor(colorSpace: space, components: values),
            let converted = color.converted(to: Self.sRGBSpace, intent: .defaultIntent, options: nil),
            let parts = converted.components, parts.count >= 3
        else { return nil }
        self.init(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}
