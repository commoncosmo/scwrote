import Testing
@testable import ScwroteCore

struct SearchResultsTests {
    private func match(_ path: String, _ line: Int) -> SearchMatch {
        SearchMatch(path: path, line: line, column: 0, text: "x", ranges: [0..<1])
    }

    private func keys(_ results: SearchResults) -> [String] {
        results.matches.map { "\($0.path):\($0.line)" }
    }

    @Test func keepsPathThenLineOrder() {
        var results = SearchResults()
        results.add([match("b", 3), match("a", 9)])
        results.add([match("a", 2), match("b", 1)])
        #expect(keys(results) == ["a:2", "a:9", "b:1", "b:3"])
    }

    @Test func ignoresDuplicatesByKey() {
        var results = SearchResults()
        results.add([match("a", 1), match("a", 1)])
        results.add([match("a", 1)])
        #expect(results.matches.count == 1)
    }

    @Test func topRowStaysSelectedUntilTheUserMoves() {
        var results = SearchResults()
        results.add([match("b", 1)])
        #expect(results.selected?.key == match("b", 1).key)
        results.add([match("a", 1)])
        #expect(results.selected?.key == match("a", 1).key)
        #expect(results.selectedIndex == 0)
    }

    @Test func selectionHoldsItsMatchAfterMoving() {
        var results = SearchResults()
        results.add([match("a", 1), match("b", 1)])
        results.move(by: 1)
        results.add([match("a", 0)])
        #expect(results.selected?.key == match("b", 1).key)
        #expect(results.selectedIndex == 2)
    }

    @Test func selectFirstAndLastMarkTheUserAsHavingMoved() {
        var results = SearchResults()
        results.add([match("a", 1), match("b", 1)])
        results.selectFirst()
        results.add([match("0", 1)])
        #expect(results.selected?.key == match("a", 1).key)
        results.selectLast()
        results.add([match("z", 1)])
        #expect(results.selected?.key == match("b", 1).key)
    }

    @Test func capsAtOneThousand() {
        var results = SearchResults()
        results.add((0..<1005).map { match("a", $0) })
        #expect(results.matches.count == 1000)
        #expect(results.isCapped)
        #expect(results.countLine == "1000+ matches")
    }

    @Test func countLines() {
        var results = SearchResults()
        #expect(results.countLine == "Searching…")
        results.finish()
        #expect(results.countLine == "No matches")

        var running = SearchResults()
        running.add([match("a", 1), match("a", 2), match("b", 1)])
        #expect(running.countLine == "3 matches · 2 files")
        running.finish()
        #expect(running.countLine == "3 matches · 2 files")

        var single = SearchResults()
        single.add([match("a", 1)])
        #expect(single.countLine == "1 matches · 1 files")
    }

    @Test func moveClampsAndHandlesEmpty() {
        var results = SearchResults()
        results.move(by: -1)
        #expect(results.selected == nil)
        #expect(results.selectedIndex == nil)

        results.add([match("a", 1), match("a", 2), match("a", 3)])
        results.move(by: 50)
        #expect(results.selectedIndex == 2)
        results.move(by: -50)
        #expect(results.selectedIndex == 0)
    }
}
