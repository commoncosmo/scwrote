import Testing
@testable import ScwroteCore

struct QuickOpenOverlayTests {
    @Test func enterOpensTheSelectedRow() {
        var o = QuickOpenOverlay()
        o.results.replace(with: QuickOpenRanking.rank(.init(""), root: "/r", files: ["a", "b"], openFiles: [], history: [], showsHidden: true))
        _ = o.handle(.next, pageHeight: 10)
        #expect(o.handle(.enter, pageHeight: 10) == .open(QuickOpenRow(path: "/r/b", relativePath: "b", ranges: [])))
    }

    @Test func toggleHiddenAsks() {
        var o = QuickOpenOverlay()
        #expect(o.toggleHidden() == .toggleHidden)
    }

    @Test func toggleHiddenClearsAPendingG() {
        var o = QuickOpenOverlay()
        o.results.replace(with: QuickOpenRanking.rank(.init(""), root: "/r", files: ["a", "b"], openFiles: [], history: [], showsHidden: true))
        _ = o.handle(.escape, pageHeight: 10)
        _ = o.handle(.next, pageHeight: 10)
        _ = o.handle(.character("g"), pageHeight: 10)
        _ = o.toggleHidden()
        _ = o.handle(.character("g"), pageHeight: 10)
        #expect(o.results.selectedIndex == 1)
    }
}
