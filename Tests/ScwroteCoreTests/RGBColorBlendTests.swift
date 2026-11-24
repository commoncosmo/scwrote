import AppKit
import Testing
@testable import ScwroteCore

/// `blended` must mix the way the theme always has, `NSColor.blended`, so a
/// theme without nvim's colors looks as it did before they were used.
struct RGBColorBlendTests {
    private static let pairs: [(top: Int, base: Int)] = [
        (0x14161b, 0xe0e2ea), // dark on light: nvim's default light
        (0xe0e2ea, 0x14161b), // light on dark: nvim's default dark
        (0xdddddd, 0x222222),
        (0xff0080, 0x0028c8),
        (0xffffff, 0x000000),
    ]

    @Test(arguments: [0.5, 0.22, 0.1, 0.15])
    func blendMatchesAppKitsBlend(amount: Double) throws {
        for (top, base) in Self.pairs {
            let blended = RGBColor(rgb: top).blended(into: RGBColor(rgb: base), amount)
            let appKit = try #require(
                nsColor(base).blended(withFraction: amount, of: nsColor(top))?.usingColorSpace(.sRGB))

            let expected = [appKit.redComponent, appKit.greenComponent, appKit.blueComponent].map(Double.init)
            let actual = [blended.red, blended.green, blended.blue]
            for (a, e) in zip(actual, expected) {
                #expect(abs(a - e) <= 1.0 / 255, "\(String(top, radix: 16)) into \(String(base, radix: 16)) at \(amount): \(actual) vs \(expected)")
            }
        }
    }

    @Test func contrastRatioMatchesWCAG() {
        let black = RGBColor(rgb: 0x000000), white = RGBColor(rgb: 0xffffff)
        #expect(abs(black.contrastRatio(with: white) - 21) <= 0.01)
        #expect(abs(white.contrastRatio(with: black) - 21) <= 0.01)
        #expect(white.contrastRatio(with: white) == 1)
        #expect(abs(RGBColor(rgb: 0x777777).contrastRatio(with: white) - 4.48) <= 0.01)
    }

    private func nsColor(_ rgb: Int) -> NSColor {
        let color = RGBColor(rgb: rgb)
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
