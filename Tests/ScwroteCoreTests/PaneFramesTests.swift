import Testing
@testable import ScwroteCore

struct PaneFramesTests {
    private func layout(browser: Bool = false, pinned: Bool = false, preview: Bool = false) -> PaneLayout {
        var layout = PaneLayout(startsInBrowser: false)
        if pinned { layout.togglePin() } else if browser { layout.toggleBrowser() }
        if preview { layout.togglePreview() }
        return layout
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

    @Test func draggedWidthsAreClamped() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 1200, browserWidth: 20, previewWidth: 5000)
        #expect(frames.browser?.width == 160)
        #expect(frames.editor.width == 320)
        #expect(frames.preview?.width == 718)
    }
}
