import Testing

@testable import ScwroteCore

private func color(_ rgb: Int) -> RGBColor { RGBColor(rgb: rgb) }

private let ghostty = GhosttyColors(
    background: color(0x101010), foreground: color(0xe0e0e0), selectionBackground: color(0x334455),
    palette3: color(0xaaaa00), palette4: color(0x0000aa))

private func group(fg: Int? = nil, bg: Int? = nil, reverse: Bool = false) -> NvimColors.Group {
    NvimColors.Group(fg: fg.map(color), bg: bg.map(color), reverse: reverse)
}

@Suite struct ThemeColorsTests {
    @Test func withoutNvimItMatchesTodaysTheme() {
        let theme = ThemeColors.resolve(nvim: nil, ghostty: ghostty)
        let bg = color(0x101010)
        let fg = color(0xe0e0e0)
        #expect(theme.background == bg)
        #expect(theme.foreground == fg)
        #expect(theme.dim == fg.blended(into: bg, 0.5))
        #expect(theme.selection == color(0x334455))
        #expect(theme.visual == color(0x334455))
        #expect(theme.visualText == fg)
        #expect(theme.selectionInactive == fg.blended(into: bg, 0.1))
        #expect(theme.folder == color(0x0000aa))
        #expect(theme.warning == color(0xaaaa00))
        #expect(theme.divider == fg.blended(into: bg, 0.15))

        let empty = ThemeColors.resolve(nvim: nil, ghostty: GhosttyColors())
        let white13 = RGBColor(red: 0.13, green: 0.13, blue: 0.13)
        let white85 = RGBColor(red: 0.85, green: 0.85, blue: 0.85)
        #expect(empty.background == white13)
        #expect(empty.foreground == white85)
        #expect(empty.selection == white85.blended(into: white13, 0.22))
        #expect(empty.visual == empty.selection)
        #expect(empty.visualText == white85)
        #expect(empty.folder == nil)
        #expect(empty.warning == nil)
    }

    @Test func nvimGroupsMapToThemeFields() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020),
            "Visual": group(fg: 0xffffff, bg: 0x445566),
            "Directory": group(fg: 0x1188ff),
            "WarningMsg": group(fg: 0xffaa00),
            "DiagnosticWarn": group(fg: 0x999900),
            "WinSeparator": group(fg: 0x555555),
            "VertSplit": group(fg: 0x777777),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        let bg = color(0x202020)
        let fg = color(0xcccccc)
        #expect(theme.background == bg)
        #expect(theme.foreground == fg)
        // Text in Normal's color is drawn on the selection, so it stays the
        // blend even though Visual sets a background.
        #expect(theme.selection == fg.blended(into: bg, 0.22))
        #expect(theme.visual == color(0x445566))
        #expect(theme.visualText == color(0xffffff))
        #expect(theme.folder == color(0x1188ff))
        #expect(theme.warning == color(0xffaa00))
        #expect(theme.divider == color(0x555555))
        #expect(theme.dim == fg.blended(into: bg, 0.5))
        #expect(theme.selectionInactive == fg.blended(into: bg, 0.1))
    }

    @Test func warningFallsBackToDiagnosticWarn() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "DiagnosticWarn": group(fg: 0x999900),
        ])
        #expect(ThemeColors.resolve(nvim: nvim, ghostty: ghostty).warning == color(0x999900))
    }

    @Test func dividerFallsBackToVertSplit() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "VertSplit": group(fg: 0x777777),
        ])
        #expect(ThemeColors.resolve(nvim: nvim, ghostty: ghostty).divider == color(0x777777))
    }

    @Test func visualWithoutBackgroundFallsBackToTheBlend() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(fg: 0xeeeeee),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.visual == color(0xcccccc).blended(into: color(0x202020), 0.22))
        #expect(theme.visualText == color(0xeeeeee))
    }

    @Test func visualWithoutForegroundUsesTheForeground() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(bg: 0x445566),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.visualText == theme.foreground)
        #expect(theme.visual == color(0x445566))
    }

    /// nvim draws a `reverse` group with its colors swapped, a missing one
    /// taken from Normal.
    @Test func reversedVisualSwapsBothColors() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(fg: 0xffaf00, bg: 0x000000, reverse: true),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.visual == color(0xffaf00))
        #expect(theme.visualText == color(0x000000))
        #expect(theme.selection == color(0xcccccc).blended(into: color(0x202020), 0.22))
    }

    @Test func reversedVisualWithOneColorTakesTheOtherFromNormal() {
        let fgOnly = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(fg: 0xffaf00, reverse: true),
        ])
        let a = ThemeColors.resolve(nvim: fgOnly, ghostty: ghostty)
        #expect(a.visual == color(0xffaf00))
        #expect(a.visualText == color(0x202020))

        let bgOnly = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(bg: 0x000000, reverse: true),
        ])
        let b = ThemeColors.resolve(nvim: bgOnly, ghostty: ghostty)
        #expect(b.visual == color(0xcccccc))
        #expect(b.visualText == color(0x000000))
    }

    @Test func reversedVisualWithNoColorsIsNormalSwapped() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(reverse: true),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.visual == color(0xcccccc))
        #expect(theme.visualText == color(0x202020))
    }

    /// "Normal in use" is the resolved pair: a transparent Normal's is Ghostty's.
    @Test func reversedVisualUnderTransparentNormalUsesGhosttysPair() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc), "Visual": group(reverse: true),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.visual == color(0xe0e0e0))
        #expect(theme.visualText == color(0x101010))
    }

    @Test func missingGroupsKeepTodaysFallbacks() {
        let nvim = NvimColors(background: "dark", groups: ["Normal": group(fg: 0xcccccc, bg: 0x202020)])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        let bg = color(0x202020)
        let fg = color(0xcccccc)
        #expect(theme.folder == color(0x0000aa))
        #expect(theme.warning == color(0xaaaa00))
        #expect(theme.divider == fg.blended(into: bg, 0.15))
        #expect(theme.selection == fg.blended(into: bg, 0.22))
        #expect(theme.visual == theme.selection)
    }

    /// With a report, Ghostty's selection-background no longer applies.
    @Test func reportIgnoresGhosttysSelectionBackground() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Visual": group(bg: 0x445566),
        ])
        #expect(ThemeColors.resolve(nvim: nvim, ghostty: ghostty).selection
            == color(0xcccccc).blended(into: color(0x202020), 0.22))
    }

    @Test func emptySentGroupCountsAsMissing() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc, bg: 0x202020), "Directory": group(), "Visual": group(),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.folder == color(0x0000aa))
        #expect(theme.visual == color(0xcccccc).blended(into: color(0x202020), 0.22))
        #expect(theme.visualText == color(0xcccccc))
    }

    @Test func transparentNormalTakesGhosttysPair() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xcccccc), "Directory": group(fg: 0x1188ff),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.background == color(0x101010))
        #expect(theme.foreground == color(0xe0e0e0))
        #expect(theme.folder == color(0x1188ff))
    }

    // MARK: The file browser's shade

    @Test func browserTakesScwroteBrowsersBackground() {
        let nvim = NvimColors(background: "light", groups: [
            "Normal": group(fg: 0x2b2823, bg: 0xf3efe7), "ScwroteBrowser": group(bg: 0xe9e3d6),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        let shade = color(0xe9e3d6)
        #expect(theme.background == color(0xf3efe7))
        #expect(theme.browserBackground == shade)
        #expect(theme.browserSelectionInactive == color(0x2b2823).blended(into: shade, 0.1))
    }

    @Test func browserFallsBackToNormalWithoutTheGroup() {
        let nvim = NvimColors(background: "dark", groups: ["Normal": group(fg: 0xcccccc, bg: 0x202020)])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.browserBackground == theme.background)
        #expect(theme.browserDim == theme.dim)
        #expect(theme.browserSelectionInactive == theme.selectionInactive)

        let withoutNvim = ThemeColors.resolve(nvim: nil, ghostty: ghostty)
        #expect(withoutNvim.browserBackground == withoutNvim.background)
        #expect(withoutNvim.browserDim == withoutNvim.dim)
        #expect(withoutNvim.browserSelectionInactive == withoutNvim.selectionInactive)
    }

    /// A shade with no text color of its own: the dim text is blended over
    /// the shade, not over the editor's background.
    @Test func browserDimIsBlendedOverTheShade() {
        let nvim = NvimColors(background: "light", groups: [
            "Normal": group(fg: 0x2b2823, bg: 0xf3efe7), "ScwroteBrowser": group(bg: 0xe9e3d6),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.browserDim == color(0x2b2823).blended(into: color(0xe9e3d6), 0.5))
        #expect(theme.browserDim != theme.dim)
    }

    /// The palettes give the shade a text color of their own for dim text,
    /// since a blend can fall under 3:1 on a light shade.
    @Test func browserDimIsTheShadesOwnTextColor() {
        let nvim = NvimColors(background: "light", groups: [
            "Normal": group(fg: 0x2b2823, bg: 0xf3efe7), "ScwroteBrowser": group(fg: 0x867c6b, bg: 0xe9e3d6),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.browserDim == color(0x867c6b))
        // The editor's own dim text is unchanged.
        #expect(theme.dim == color(0x2b2823).blended(into: color(0xf3efe7), 0.5))
    }

    /// nvim 0.12's default colors link WinSeparator to Normal, so the divider
    /// is the text color: code blocks and diagram fills take their own fade
    /// of the text, which text stays readable on.
    @Test func fillIsReadableWhenTheDividerIsTheTextColor() {
        let nvim = NvimColors(background: "dark", groups: [
            "Normal": group(fg: 0xe0e2ea, bg: 0x14161b), "WinSeparator": group(fg: 0xe0e2ea),
        ])
        let theme = ThemeColors.resolve(nvim: nvim, ghostty: ghostty)
        #expect(theme.fill != theme.divider)
        #expect(theme.foreground.contrastRatio(with: theme.fill) >= 4.5)
        #expect(theme.fill == color(0xe0e2ea).blended(into: color(0x14161b), 0.1))
    }
}
