import Testing
@testable import ScwroteCore

private func ranked(_ name: String, _ paths: [String]) -> [String] {
    var hits: [(path: String, score: Int)] = []
    for path in paths {
        if let match = FuzzyMatcher.match(name, in: path) { hits.append((path, match.score)) }
    }
    hits.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }
    return hits.map(\.path)
}

private let repo = [
    "Sources/Scwrote/EditorWindowController.swift",
    "Sources/Scwrote/EditorWindowController+Search.swift",
    "Sources/Scwrote/EditorWindowController+Preview.swift",
    "Sources/Scwrote/EditorLayoutView.swift",
    "Sources/Scwrote/Theme.swift",
    "Sources/ScwroteCore/BackgroundTone.swift",
    "Tests/ScwroteCoreTests/BackgroundToneTests.swift",
    "Sources/Scwrote/FileBrowserView.swift",
    "Sources/ScwroteCore/FileBrowser.swift",
    "web/src/main.ts",
    ".github/workflows/release.yml",
]

struct FuzzyMatcherTests {
    @Test func humpsFindTheFile() {
        #expect(ranked("ewc", repo).first == "Sources/Scwrote/EditorWindowController.swift")
        #expect(ranked("ewcs", repo).first == "Sources/Scwrote/EditorWindowController+Search.swift")
    }
    @Test func fileNameBeatsFolders() {
        #expect(ranked("theme", repo).first == "Sources/Scwrote/Theme.swift")
    }
    @Test func shorterPathWinsATie() {
        #expect(ranked("backgroundtone", repo).first == "Sources/ScwroteCore/BackgroundTone.swift")
    }
    @Test func slashNarrowsByFolder() {
        #expect(ranked("core/filebrowser", repo) == ["Sources/ScwroteCore/FileBrowser.swift"])
    }
    @Test func capitalPrefersTheHump() {
        #expect(ranked("V", ["a/Preview.swift", "a/PreView.swift"]).first == "a/PreView.swift")
    }
    @Test func outOfOrderDoesNotMatch() { #expect(FuzzyMatcher.match("cwe", in: "ewc.swift") == nil) }
    @Test func termsMatchInAnyOrder() {
        #expect(FuzzyMatcher.match("search editor", in: "Sources/Scwrote/EditorWindowController+Search.swift") != nil)
        #expect(FuzzyMatcher.match("editor zzz", in: "Sources/Scwrote/EditorWindowController.swift") == nil)
    }
    @Test func emptyNameMatchesEverything() {
        #expect(FuzzyMatcher.match("  ", in: "a.txt") == FuzzyMatch(score: 0, ranges: []))
    }
    @Test func rangesMarkTheMatchedCharacters() {
        #expect(FuzzyMatcher.match("ewc", in: "EditorWindowController.swift")!.ranges == [0..<1, 6..<7, 12..<13])
        #expect(FuzzyMatcher.match("edit", in: "EditorWindowController.swift")!.ranges == [0..<4])
    }
    @Test func dotfilesMatch() { #expect(ranked("release", repo).first == ".github/workflows/release.yml") }
    @Test func nonASCIIPathsMatchWithUTF16Ranges() {
        #expect(FuzzyMatcher.match("resume", in: "docs/Résumé.md")!.ranges == [5..<11])
        #expect(FuzzyMatcher.match("語", in: "日本語.txt")!.ranges == [2..<3])
        #expect(FuzzyMatcher.match("ab", in: "😀a/b.txt")!.ranges == [2..<3, 4..<5])
    }

    @Test func gapCostsFiveThenOneMore() {
        // Against the run, a one-character gap loses the run bonus (8) and pays 5; two pay one more.
        let run = FuzzyMatcher.match("ab", in: "ab")!.score
        let one = FuzzyMatcher.match("ab", in: "axb")!.score
        let two = FuzzyMatcher.match("ab", in: "axxb")!.score
        #expect(run - one == 8 + 5)
        #expect(one - two == 1)
    }
    @Test func fileNameHitBeatsWordStartInAFolder() {
        // "x" is a word start in the folder "a/x_y/", only mid-word in the file name "zxz.md".
        let folder = FuzzyMatcher.match("x", in: "a/x_y/zzz.md")!.score
        let file = FuzzyMatcher.match("x", in: "a/q_y/zxz.md")!.score
        #expect(file > folder)
    }
    @Test func aPreparedPatternMatchesLikeTheName() {
        let pattern = FuzzyPattern("ewc s")
        for path in repo {
            #expect(FuzzyMatcher.match(pattern, in: path) == FuzzyMatcher.match("ewc s", in: path))
        }
    }
}
