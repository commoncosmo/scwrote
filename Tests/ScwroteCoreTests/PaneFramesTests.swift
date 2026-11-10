import Testing
@testable import ScwroteCore

struct PaneFramesTests {
    private func layout(
        browser: Bool = false, pinned: Bool = false, preview: Bool = false, focus: PaneLayout.Pane = .editor
    ) -> PaneLayout {
        var layout = PaneLayout(startsInBrowser: false)
        if pinned { layout.togglePin() } else if browser { layout.toggleBrowser() }
        if preview { layout.togglePreview() }
        switch focus {
        case .editor: layout.leavePreview() // an unpinned browser stays shown
        case .browser: layout.focusBrowser()
        case .preview: break
        }
        #expect(layout.focus == focus)
        return layout
    }
    private func frames(_ layout: PaneLayout, _ totalWidth: Double) -> PaneFrames {
        PaneFrames.compute(layout, totalWidth: totalWidth, browserWidth: 280, previewWidth: 420)
    }
    private func span(_ x: Double, _ width: Double) -> PaneFrames.Span { .init(x: x, width: width) }

    @Test func editorAloneFillsTheWindow() {
        let frames = PaneFrames.compute(layout(), totalWidth: 1000, browserWidth: 280, previewWidth: 420)
        #expect(frames.editor == span(0, 1000) && frames.browser == nil && frames.preview == nil)
    }

    @Test func allThreeSideBySide() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 1200, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == span(0, 280))
        #expect(frames.editor == span(281, 498))
        #expect(frames.preview == span(780, 420))
        #expect(frames.gaveWay.isEmpty)
    }

    @Test func unpinnedBrowserGivesWayFirst() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 700, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == nil && frames.gaveWay == [.browser])
        #expect(frames.editor == span(0, 320))
        #expect(frames.preview == span(321, 379))
    }

    @Test func thenThePreview() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 500, browserWidth: 280, previewWidth: 420)
        #expect(frames.gaveWay == [.browser, .preview] && frames.editor == span(0, 500))
    }

    @Test func aPinnedBrowserNeverGivesWay() {
        let frames = PaneFrames.compute(layout(pinned: true, preview: true), totalWidth: 700, browserWidth: 280, previewWidth: 420)
        #expect(frames.gaveWay == [.preview])
        #expect(frames.browser == span(0, 280) && frames.editor == span(281, 419))
    }

    @Test func aPinnedBrowserKeepsItsMinimumInATinyWindow() {
        let frames = PaneFrames.compute(layout(pinned: true), totalWidth: 400, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == span(0, 160) && frames.editor == span(161, 239))
    }

    @Test func widerAgainBringsThemBack() {
        let wanted = layout(browser: true, preview: true)
        _ = PaneFrames.compute(wanted, totalWidth: 500, browserWidth: 280, previewWidth: 420)
        #expect(PaneFrames.compute(wanted, totalWidth: 1200, browserWidth: 280, previewWidth: 420).gaveWay.isEmpty)
    }

    @Test func previewBesideTheFullWindowBrowser() {
        var start = PaneLayout(startsInBrowser: true)
        start.openedViewOnlyFile()
        let frames = PaneFrames.compute(start, totalWidth: 1000, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == span(0, 579) && frames.editor == span(0, 579) && frames.preview == span(580, 420))
    }

    // MARK: The pane with the keyboard never gives way

    @Test func theBrowserWithTheKeyboardKeepsAShownPreviewAndSqueezesTheEditor() {
        let frames = frames(layout(browser: true, preview: true, focus: .browser), 600)
        #expect(frames.gaveWay.isEmpty)
        #expect(frames.browser == span(0, 160) && frames.editor == span(161, 198) && frames.preview == span(360, 240))
    }

    @Test func aPreviewWithTheKeyboardStaysWhileAnUnpinnedBrowserGivesWay() {
        let frames = frames(layout(browser: true, preview: true, focus: .preview), 600)
        #expect(frames.gaveWay == [.browser])
        #expect(frames.editor == span(0, 320) && frames.preview == span(321, 279))
    }

    @Test func aPreviewWithTheKeyboardAndAPinnedBrowserSqueezeTheEditor() {
        let frames = frames(layout(pinned: true, preview: true, focus: .preview), 600)
        #expect(frames.gaveWay.isEmpty)
        #expect(frames.browser == span(0, 160) && frames.editor == span(161, 198) && frames.preview == span(360, 240))
    }

    @Test func withTheKeyboardInTheEditorTheOrderStands() {
        let narrow = frames(layout(browser: true, preview: true), 600)
        #expect(narrow.gaveWay == [.browser] && narrow.editor == span(0, 320) && narrow.preview == span(321, 279))
        #expect(frames(layout(browser: true, preview: true), 500).gaveWay == [.browser, .preview])
    }

    /// Cmd+1 from the editor with the preview shown, in a window too narrow for all three.
    @Test func cmd1WithThePreviewShownBringsTheBrowserBesideIt() {
        var layout = layout(preview: true)
        layout.toggleBrowser()

        let frames = frames(layout, 600)
        #expect(frames.gaveWay.isEmpty && frames.browser != nil && frames.preview != nil)
    }

    @Test func theEditorCanBeSqueezedToNothing() {
        let frames = frames(layout(browser: true, preview: true, focus: .browser), 402)
        #expect(frames.gaveWay.isEmpty)
        #expect(frames.browser == span(0, 160) && frames.editor == span(161, 0) && frames.preview == span(162, 240))
    }

    /// Below 402 pt both side panes can't fit even with no editor.
    @Test func whenEvenThatIsNotEnoughThePaneWithoutTheKeyboardGoes() {
        let browsing = frames(layout(browser: true, preview: true, focus: .browser), 380)
        #expect(browsing.gaveWay == [.preview] && browsing.browser == span(0, 160))
        let previewing = frames(layout(pinned: true, preview: true, focus: .preview), 380)
        #expect(previewing.gaveWay == [.browser] && previewing.preview == span(140, 240))
    }

    @Test func draggedWidthsAreClamped() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 1200, browserWidth: 20, previewWidth: 5000)
        #expect(frames.browser?.width == 160)
        #expect(frames.editor.width == 320)
        #expect(frames.preview?.width == 718)
    }
}
