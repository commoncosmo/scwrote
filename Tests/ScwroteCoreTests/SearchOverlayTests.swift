import Testing
@testable import ScwroteCore

struct SearchOverlayTests {
    private func match(_ path: String, _ line: Int) -> SearchMatch {
        SearchMatch(path: path, line: line, column: 0, text: "x", ranges: [0..<1])
    }

    private func overlay(rows: Int = 0) -> SearchOverlay {
        var overlay = SearchOverlay()
        overlay.results.add((1...max(rows, 1)).prefix(rows).map { match("a", $0) })
        return overlay
    }

    private func selectedLine(_ overlay: SearchOverlay) -> Int? { overlay.results.selected?.line }

    @Test func typingChangesTheQuery() {
        var overlay = SearchOverlay()
        #expect(overlay.handle(.character("n"), pageHeight: 10) == .queryChanged("n"))
        #expect(overlay.handle(.character("e"), pageHeight: 10) == .queryChanged("ne"))
        #expect(overlay.query.text == "ne")
        #expect(overlay.handle(.edit(.left), pageHeight: 10) == nil)
        #expect(overlay.handle(.edit(.character("x")), pageHeight: 10) == .queryChanged("nxe"))
        #expect(overlay.handle(.edit(.backspace), pageHeight: 10) == .queryChanged("ne"))
    }

    @Test func jkAreTextWhileTyping() {
        var overlay = overlay(rows: 3)
        #expect(overlay.handle(.character("j"), pageHeight: 10) == .queryChanged("j"))
        #expect(selectedLine(overlay) == 1)
    }

    @Test func nextAndPreviousMoveInBothModes() {
        var overlay = overlay(rows: 4)
        #expect(overlay.handle(.next, pageHeight: 10) == nil)
        #expect(selectedLine(overlay) == 2)
        #expect(overlay.handle(.previous, pageHeight: 10) == nil)
        #expect(selectedLine(overlay) == 1)
        _ = overlay.handle(.escape, pageHeight: 10)
        _ = overlay.handle(.next, pageHeight: 10)
        _ = overlay.handle(.next, pageHeight: 10)
        #expect(selectedLine(overlay) == 3)
        _ = overlay.handle(.previous, pageHeight: 10)
        #expect(selectedLine(overlay) == 2)
    }

    @Test func escapeGoesToTheListThenCloses() {
        var overlay = SearchOverlay()
        #expect(overlay.mode == .typing)
        #expect(overlay.handle(.escape, pageHeight: 10) == nil)
        #expect(overlay.mode == .list)
        #expect(overlay.handle(.escape, pageHeight: 10) == .close)
    }

    @Test func listKeys() {
        var overlay = overlay(rows: 20)
        _ = overlay.handle(.escape, pageHeight: 10)
        _ = overlay.handle(.character("j"), pageHeight: 10)
        _ = overlay.handle(.character("j"), pageHeight: 10)
        #expect(selectedLine(overlay) == 3)
        _ = overlay.handle(.character("k"), pageHeight: 10)
        #expect(selectedLine(overlay) == 2)
        _ = overlay.handle(.character("G"), pageHeight: 10)
        #expect(selectedLine(overlay) == 20)
        _ = overlay.handle(.character("g"), pageHeight: 10)
        #expect(selectedLine(overlay) == 20)
        _ = overlay.handle(.character("g"), pageHeight: 10)
        #expect(selectedLine(overlay) == 1)
        _ = overlay.handle(.halfPageDown, pageHeight: 10)
        #expect(selectedLine(overlay) == 6)
        _ = overlay.handle(.halfPageUp, pageHeight: 10)
        #expect(selectedLine(overlay) == 1)
        _ = overlay.handle(.halfPageDown, pageHeight: 1)
        #expect(selectedLine(overlay) == 2)
        #expect(overlay.query.text == "")
    }

    @Test func otherKeysClearAPendingG() {
        var overlay = overlay(rows: 5)
        _ = overlay.handle(.escape, pageHeight: 10)
        _ = overlay.handle(.character("G"), pageHeight: 10)
        _ = overlay.handle(.character("g"), pageHeight: 10)
        #expect(overlay.handle(.character("x"), pageHeight: 10) == nil)
        _ = overlay.handle(.character("g"), pageHeight: 10)
        #expect(selectedLine(overlay) == 5)
        _ = overlay.handle(.character("g"), pageHeight: 10)
        #expect(selectedLine(overlay) == 1)
        #expect(overlay.query.text == "")
    }

    @Test func editCharacterIsACharacter() {
        var overlay = overlay(rows: 5)
        _ = overlay.handle(.escape, pageHeight: 10)
        _ = overlay.handle(.character("G"), pageHeight: 10)
        _ = overlay.handle(.edit(.character("g")), pageHeight: 10)
        _ = overlay.handle(.edit(.character("g")), pageHeight: 10)
        #expect(selectedLine(overlay) == 1)
    }

    @Test func iAndSlashReturnToTyping() {
        for key: Character in ["i", "/"] {
            var overlay = SearchOverlay()
            _ = overlay.handle(.escape, pageHeight: 10)
            #expect(overlay.handle(.character(key), pageHeight: 10) == nil)
            #expect(overlay.mode == .typing)
            #expect(overlay.query.text == "")
        }
    }

    @Test func ctrlUInTypingClearsTheQuery() {
        var overlay = SearchOverlay()
        _ = overlay.handle(.character("a"), pageHeight: 10)
        _ = overlay.handle(.character("b"), pageHeight: 10)
        #expect(overlay.handle(.halfPageUp, pageHeight: 10) == .queryChanged(""))
        #expect(overlay.handle(.halfPageUp, pageHeight: 10) == nil)
        _ = overlay.handle(.character("c"), pageHeight: 10)
        #expect(overlay.handle(.halfPageDown, pageHeight: 10) == nil)
        #expect(overlay.query.text == "c")
    }

    @Test func enterOpensTheSelected() {
        var empty = SearchOverlay()
        #expect(empty.handle(.enter, pageHeight: 10) == nil)
        var overlay = overlay(rows: 3)
        _ = overlay.handle(.next, pageHeight: 10)
        #expect(overlay.handle(.enter, pageHeight: 10) == .open(match("a", 2)))
        _ = overlay.handle(.escape, pageHeight: 10)
        #expect(overlay.handle(.enter, pageHeight: 10) == .open(match("a", 2)))
    }

    @Test func reopenSelectsTheQuery() {
        var overlay = SearchOverlay()
        _ = overlay.handle(.character("a"), pageHeight: 10)
        _ = overlay.handle(.character("b"), pageHeight: 10)
        _ = overlay.handle(.character("c"), pageHeight: 10)
        _ = overlay.handle(.escape, pageHeight: 10)
        overlay.reopen()
        #expect(overlay.mode == .typing)
        #expect(overlay.isQuerySelected)
        #expect(overlay.query.text == "abc")
        #expect(overlay.handle(.character("x"), pageHeight: 10) == .queryChanged("x"))
        #expect(!overlay.isQuerySelected)

        overlay.reopen()
        #expect(overlay.handle(.edit(.left), pageHeight: 10) == nil)
        #expect(!overlay.isQuerySelected)
        #expect(overlay.query.text == "x")
        #expect(overlay.query.cursor == 0)
        #expect(overlay.handle(.character("y"), pageHeight: 10) == .queryChanged("yx"))

        overlay.reopen()
        #expect(overlay.handle(.edit(.right), pageHeight: 10) == nil)
        #expect(overlay.query.cursor == 2)

        overlay.reopen()
        #expect(overlay.handle(.edit(.backspace), pageHeight: 10) == .queryChanged(""))
        #expect(!overlay.isQuerySelected)
    }

    @Test func reopenedQueryClearsWithDeleteKeys() {
        for key in [PromptKey.backspace, .deleteWord, .deleteToStart] {
            var overlay = SearchOverlay()
            _ = overlay.handle(.character("a"), pageHeight: 10)
            overlay.reopen()
            #expect(overlay.handle(.edit(key), pageHeight: 10) == .queryChanged(""))
        }
        var overlay = SearchOverlay()
        _ = overlay.handle(.character("a"), pageHeight: 10)
        overlay.reopen()
        #expect(overlay.handle(.halfPageUp, pageHeight: 10) == .queryChanged(""))
    }

    @Test func pasteInserts() {
        var overlay = SearchOverlay()
        #expect(overlay.paste("a\nb") == .queryChanged("a b"))
        #expect(overlay.paste("c\r\nd\re") == .queryChanged("a bc d e"))
        #expect(overlay.paste("") == nil)
    }

    @Test func pasteReplacesASelectedQuery() {
        var overlay = SearchOverlay()
        _ = overlay.handle(.character("a"), pageHeight: 10)
        overlay.reopen()
        #expect(overlay.paste("zz") == .queryChanged("zz"))
        #expect(!overlay.isQuerySelected)
    }
}
