import Testing

@testable import ScwroteCore

private let files = ["a/OneView.swift", "b/TwoView.swift", "docs/FileBrowserView.swift", "xfxbxv.txt", ".github/ci.yml", "z.txt"]

@Suite struct QuickOpenResultsTests {
    @Test func openFilesWinEqualMatches() {
        let r = QuickOpenRanking.rank(.init("view"), root: "/r", files: files.sorted(), openFiles: ["b/TwoView.swift"], history: [], showsHidden: true)
        #expect(r.rows.first?.relativePath == "b/TwoView.swift")
    }

    @Test func openFileBonusDoesNotRescueAPoorMatch() {
        let r = QuickOpenRanking.rank(.init("fbv"), root: "/r", files: files.sorted(), openFiles: ["xfxbxv.txt"], history: [], showsHidden: true)
        #expect(r.rows.first?.relativePath == "docs/FileBrowserView.swift")
    }

    @Test func emptyQueryListsOpenThenHistoryThenTheRest() {
        let r = QuickOpenRanking.rank(.init(""), root: "/r", files: files.sorted(), openFiles: ["z.txt"], history: ["a/OneView.swift", "z.txt", "gone.txt"], showsHidden: true)
        #expect(r.rows.map(\.relativePath) == ["z.txt", "a/OneView.swift", ".github/ci.yml", "b/TwoView.swift", "docs/FileBrowserView.swift", "xfxbxv.txt"])
        #expect(r.countLine == "6 files")
    }

    @Test func spacesOnlyQueryListsRecents() {
        let r = QuickOpenRanking.rank(.init("   "), root: "/r", files: files.sorted(), openFiles: ["z.txt"], history: [], showsHidden: true)
        #expect(r.rows.first?.relativePath == "z.txt" && r.isEmptyQuery)
    }

    @Test func hiddenOffDropsDotPathsEverywhere() {
        let r = QuickOpenRanking.rank(.init(""), root: "/r", files: files.sorted(), openFiles: [".github/ci.yml"], history: [], showsHidden: false)
        #expect(!r.rows.contains { $0.relativePath == ".github/ci.yml" })
        #expect(r.countLine == "5 files · hidden off")
    }

    @Test func countLines() {
        #expect(QuickOpenResults().countLine == "Listing files…")
        #expect(QuickOpenRanking.rank(.init("view"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: true).countLine == "3 of 6 files")
        #expect(QuickOpenRanking.rank(.init("qqq"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: false).countLine == "No files · hidden off")
        #expect(QuickOpenRanking.rank(.init("z"), root: "/r", files: ["z.txt"], openFiles: [], history: [], showsHidden: true).countLine == "1 of 1 file")
        #expect(QuickOpenRanking.rank(.init(""), root: "/r", files: ["z.txt"], openFiles: [], history: [], showsHidden: true).countLine == "1 file")
    }

    @Test func listingStateIgnoresHiddenSuffix() {
        var listing = QuickOpenResults()
        #expect(listing.isListing && listing.rows.isEmpty && listing.selectedIndex == nil)
        listing.replace(with: QuickOpenRanking.rank(.init(""), root: "/r", files: [], openFiles: [], history: [], showsHidden: false))
        #expect(!listing.isListing && listing.countLine == "No files · hidden off")
    }

    @Test func rowsCarryAbsolutePathsAndRanges() {
        let r = QuickOpenRanking.rank(.init("one"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: true)
        #expect(r.rows.first == QuickOpenRow(path: "/r/a/OneView.swift", relativePath: "a/OneView.swift", ranges: [2..<5]))
    }

    @Test func rootWithTrailingSlashDoesNotDoubleIt() {
        let r = QuickOpenRanking.rank(.init("z"), root: "/r/", files: ["z.txt"], openFiles: [], history: [], showsHidden: true)
        #expect(r.rows.first?.path == "/r/z.txt")
    }

    @Test func typingTheWholeNamePutsThatFileFirstAcrossFolders() {
        func top(_ name: String, _ files: [String]) -> String? {
            QuickOpenRanking.rank(.init(name), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: true)
                .rows.first?.relativePath
        }
        #expect(top("theme", ["Sources/App/Views/Theme.swift", "Tests/ThemeTests.swift"]) == "Sources/App/Views/Theme.swift")
        #expect(top("theme", ["src/components/Theme.tsx", "src/Theme.test.tsx"]) == "src/components/Theme.tsx")
        #expect(top("main", ["Sources/Scwrote/main.swift", "docs/domain/maintenance.md"]) == "Sources/Scwrote/main.swift")
    }

    @Test func tiesBreakByShorterPathThenPathOrder() {
        let r = QuickOpenRanking.rank(.init("x"), root: "/r", files: ["a/x", "b/x", "x"], openFiles: [], history: [], showsHidden: true)
        #expect(r.rows.map(\.relativePath) == ["x", "a/x", "b/x"])
    }

    @Test func rowsStopAtTheLimitButTheCountDoesNot() {
        let many = (0..<500).map { String(format: "f%03d.txt", $0) }
        let r = QuickOpenRanking.rank(.init("f"), root: "/r", files: many, openFiles: [], history: [], showsHidden: true)
        #expect(r.rows.count == 200 && r.matchCount == 500)
    }

    @Test func emptyQueryRowsStopAtTheLimitToo() {
        let many = (0..<500).map { String(format: "f%03d.txt", $0) }
        let r = QuickOpenRanking.rank(.init(""), root: "/r", files: many, openFiles: [], history: [], showsHidden: true)
        #expect(r.rows.count == 200 && r.matchCount == 500 && r.fileCount == 500)
    }

    @Test func selectionIsTheTopRowUntilTheUserMoves() {
        var r = QuickOpenRanking.rank(.init("view"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: true)
        #expect(r.selectedIndex == 0)
        r.move(by: 100)
        #expect(r.selectedIndex == r.rows.count - 1)
        r.move(by: -100)
        #expect(r.selectedIndex == 0)
        r.selectLast()
        #expect(r.selectedIndex == r.rows.count - 1)
        r.selectFirst()
        #expect(r.selectedIndex == 0)
    }

    @Test func replaceKeepsTheSelectionByPath() {
        var r = QuickOpenRanking.rank(.init("view"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: true)
        r.move(by: 1); let held = r.selected!.path
        r.replace(with: QuickOpenRanking.rank(.init("view"), root: "/r", files: (files + ["c/ThreeView.swift"]).sorted(), openFiles: [], history: [], showsHidden: true))
        #expect(r.selected?.path == held)
    }

    @Test func hidingTheSelectedHiddenFileSelectsTheTop() {
        let mixed = [".hidden/view.txt", "a/view.txt", "b/view2.txt"]
        var r = QuickOpenRanking.rank(.init("view"), root: "/r", files: mixed, openFiles: [], history: [], showsHidden: true)
        while r.selected?.relativePath != ".hidden/view.txt" { r.move(by: 1) }
        r.replace(with: QuickOpenRanking.rank(.init("view"), root: "/r", files: mixed, openFiles: [], history: [], showsHidden: false))
        #expect(r.selectedIndex == 0 && r.selected?.relativePath != ".hidden/view.txt")
    }

    @Test func narrowingFromThePreviousMatchesRanksAsAFullRankDoes() {
        // Over the row limit at "e", so the narrowed rankings need matches past the rows.
        let many = ((0..<400).map { "Sources/E\($0)/Editor\($0)Window.swift" } + files + [".e/EditorWindowController.swift"]).sorted()
        let open = ["Sources/E7/Editor7Window.swift"]
        let history = ["z.txt"]
        for showsHidden in [true, false] {
            var previous: QuickOpenRanked?
            for text in ["e", "ed", "edw", "edw ", "edw w", "edw wi", "edw wi:3"] {
                let query = QuickOpenQuery(text)
                let narrowed = QuickOpenRanking.rank(query, root: "/r", files: many, openFiles: open, history: history,
                                                     showsHidden: showsHidden, narrowing: previous)
                let full = QuickOpenRanking.rank(query, root: "/r", files: many, openFiles: open, history: history,
                                                 showsHidden: showsHidden)
                #expect(narrowed.results == full, "\(text) showsHidden \(showsHidden)")
                previous = narrowed
            }
            #expect(previous?.results.matchCount ?? 0 > 0)
        }
    }

    @Test func narrowingIsIgnoredWhenTheQueryDoesNotExtendOrHiddenChanged() {
        let first = QuickOpenRanking.rank(.init("view"), root: "/r", files: files.sorted(), openFiles: [], history: [],
                                          showsHidden: false, narrowing: nil)
        let shorter = QuickOpenRanking.rank(.init("vie"), root: "/r", files: files.sorted(), openFiles: [], history: [],
                                            showsHidden: false, narrowing: first)
        #expect(shorter.results == QuickOpenRanking.rank(.init("vie"), root: "/r", files: files.sorted(), openFiles: [], history: [], showsHidden: false))
        let hidden = [".v/view.txt"] + files
        let shown = QuickOpenRanking.rank(.init("view"), root: "/r", files: hidden.sorted(), openFiles: [], history: [],
                                          showsHidden: true, narrowing: QuickOpenRanking.rank(.init("vie"), root: "/r", files: hidden.sorted(), openFiles: [], history: [], showsHidden: false, narrowing: nil))
        #expect(shown.results.rows.contains { $0.relativePath == ".v/view.txt" })
        #expect(shown.results == QuickOpenRanking.rank(.init("view"), root: "/r", files: hidden.sorted(), openFiles: [], history: [], showsHidden: true))
    }

    // A speed guard where timing is reliable: release builds rank 33,000
    // paths (every one matching) in about 0.1 s on an M5 Pro, against a 1 s
    // budget for slower and busier machines. Debug builds run about ten times
    // slower and, on CI, on shared runners, so they only check the result,
    // on fewer paths to keep the suite quick.
    @Test func rankingThirtyThreeThousandPathsIsQuick() {
        #if DEBUG
        let count = 3_000
        #else
        let count = 33_000
        #endif
        let paths = (0..<count).map { "Sources/Module\($0 % 40)/Sub\($0 % 7)/File\($0)Controller.swift" }.sorted()
        let query = QuickOpenQuery("fcon")
        let first = QuickOpenRanking.rank(query, root: "/r", files: paths, openFiles: [], history: [], showsHidden: true)
        #expect(first.matchCount == count)
        #if !DEBUG
        let clock = ContinuousClock()
        for _ in 0..<5 {
            var results: QuickOpenResults?
            let elapsed = clock.measure {
                results = QuickOpenRanking.rank(query, root: "/r", files: paths, openFiles: [], history: [], showsHidden: true)
            }
            #expect(results?.matchCount == count)
            #expect(elapsed < .seconds(1))
        }
        #endif
    }
}
