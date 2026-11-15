import Testing
@testable import ScwroteCore

struct BackgroundToneTests {
    @Test func darkThemeBackgroundsAreDark() {
        // Afterglow's background, and Ghostty's own default.
        #expect(BackgroundTone.isDark(red: 0x21 / 255, green: 0x21 / 255, blue: 0x21 / 255))
        #expect(BackgroundTone.isDark(red: 0x28 / 255, green: 0x2C / 255, blue: 0x34 / 255))
    }

    @Test func lightThemeBackgroundsAreLight() {
        // Alabaster's background, and plain white.
        #expect(!BackgroundTone.isDark(red: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255))
        #expect(!BackgroundTone.isDark(red: 1, green: 1, blue: 1))
    }

    /// Green weighs most in perceived brightness, blue least.
    @Test func brightnessIsWeightedLikeTheEye() {
        #expect(!BackgroundTone.isDark(red: 0, green: 0.8, blue: 0))
        #expect(BackgroundTone.isDark(red: 0, green: 0, blue: 1))
    }
}
