import Foundation
import Testing
@testable import ScwroteCore

/// Builds a real folder tree in a temporary directory. Paths ending in "/" are
/// folders; everything else is an empty file.
private func makeTree(_ paths: [String]) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scwrote-tree-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    for path in paths {
        let full = "\(root)/\(path)"
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: full, contents: Data())
        }
    }
    return root
}

private extension FileBrowser {
    /// Visible rows as "name" (indented two spaces per level, folders end in "/").
    var outline: [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name + ($0.entry.isDirectory ? "/" : "") }
    }

    var selectedName: String? { selectedPath.map { ($0 as NSString).lastPathComponent } }

    /// Types keys the way a user would, one character at a time.
    mutating func type(_ keys: String, pageHeight: Int = 20) -> BrowserAction? {
        var last: BrowserAction?
        for key in keys { last = handle(.character(key), pageHeight: pageHeight) }
        return last
    }
}

struct FileBrowserListingTests {
    @Test func foldersComeFirstThenFilesInFinderOrder() throws {
        let root = try makeTree(["b.md", "a/", "file10.txt", "file2.txt", "Z/", ".env"])

        let browser = FileBrowser(root: root)

        #expect(browser.outline == ["a/", "Z/", ".env", "b.md", "file2.txt", "file10.txt"])
    }

    @Test func revealWorksAtTheFilesystemRoot() {
        var browser = FileBrowser(root: "/")
        browser.reveal("/usr/bin")
        #expect(browser.selectedPath == "/usr/bin")
    }

    @Test func gitFolderAndFinderJunkAreAlwaysHidden() throws {
        let root = try makeTree([".git/", ".DS_Store", "README.md"])

        var browser = FileBrowser(root: root)
        _ = browser.type("gh")
        _ = browser.type("gh")

        #expect(browser.outline == ["README.md"])
    }

    @Test func ghTogglesDotfiles() throws {
        let root = try makeTree([".env", "README.md"])
        var browser = FileBrowser(root: root)

        _ = browser.type("gh")
        #expect(browser.outline == ["README.md"])

        _ = browser.type("gh")
        #expect(browser.outline == [".env", "README.md"])
    }

    @Test func reloadPicksUpNewFilesAndKeepsTheCursorOnTheSameFile() throws {
        let root = try makeTree(["b.md", "c.md"])
        var browser = FileBrowser(root: root)
        _ = browser.type("j")
        #expect(browser.selectedName == "c.md")

        FileManager.default.createFile(atPath: "\(root)/a.md", contents: Data())
        browser.reload()

        #expect(browser.outline == ["a.md", "b.md", "c.md"])
        #expect(browser.selectedName == "c.md")
    }
}

struct FileBrowserMovementTests {
    @Test func jAndKMoveTheCursorAndStopAtTheEnds() throws {
        let root = try makeTree(["a.md", "b.md", "c.md"])
        var browser = FileBrowser(root: root)

        _ = browser.type("jjjj")
        #expect(browser.selectedName == "c.md")

        _ = browser.type("kkkkk")
        #expect(browser.selectedName == "a.md")
    }

    @Test func arrowKeysMoveLikeJAndK() throws {
        let root = try makeTree(["a.md", "b.md"])
        var browser = FileBrowser(root: root)

        _ = browser.handle(.down, pageHeight: 20)
        #expect(browser.selectedName == "b.md")

        _ = browser.handle(.up, pageHeight: 20)
        #expect(browser.selectedName == "a.md")
    }

    @Test func aCountRepeatsTheMove() throws {
        let root = try makeTree((1...12).map { String(format: "f%02d.md", $0) })
        var browser = FileBrowser(root: root)

        _ = browser.type("3j")
        #expect(browser.selectedName == "f04.md")

        _ = browser.type("10j")
        #expect(browser.selectedName == "f12.md")

        _ = browser.type("2k")
        #expect(browser.selectedName == "f10.md")
    }

    @Test func ggAndGJumpToTopAndBottom() throws {
        let root = try makeTree(["a.md", "b.md", "c.md", "d.md"])
        var browser = FileBrowser(root: root)

        _ = browser.type("G")
        #expect(browser.selectedName == "d.md")

        _ = browser.type("gg")
        #expect(browser.selectedName == "a.md")

        _ = browser.type("3G")
        #expect(browser.selectedName == "c.md")
    }

    @Test func halfPageKeysMoveByHalfThePage() throws {
        let root = try makeTree((1...30).map { String(format: "f%02d.md", $0) })
        var browser = FileBrowser(root: root)

        _ = browser.handle(.halfPageDown, pageHeight: 10)
        #expect(browser.selectedName == "f06.md")

        _ = browser.handle(.halfPageUp, pageHeight: 10)
        #expect(browser.selectedName == "f01.md")
    }

    @Test func anUnknownKeyClearsAPendingCountOrG() throws {
        let root = try makeTree(["a.md", "b.md", "c.md", "d.md"])
        var browser = FileBrowser(root: root)

        _ = browser.type("3xj")
        #expect(browser.selectedName == "b.md")

        _ = browser.type("gxg")
        #expect(browser.selectedName == "b.md")
    }
}

struct FileBrowserFolderTests {
    @Test func lExpandsAFolderAndHCollapsesIt() throws {
        let root = try makeTree(["src/main.swift", "README.md"])
        var browser = FileBrowser(root: root)

        _ = browser.type("l")
        #expect(browser.outline == ["src/", "  main.swift", "README.md"])
        #expect(browser.selectedName == "src")

        _ = browser.type("h")
        #expect(browser.outline == ["src/", "README.md"])
    }

    @Test func rightAndLeftArrowsWorkLikeLAndH() throws {
        let root = try makeTree(["src/main.swift"])
        var browser = FileBrowser(root: root)

        _ = browser.handle(.right, pageHeight: 20)
        #expect(browser.outline == ["src/", "  main.swift"])

        _ = browser.handle(.left, pageHeight: 20)
        #expect(browser.outline == ["src/"])
    }

    @Test func lOnAnOpenFolderStepsIntoIt() throws {
        let root = try makeTree(["src/main.swift"])
        var browser = FileBrowser(root: root)

        _ = browser.type("ll")

        #expect(browser.selectedName == "main.swift")
    }

    @Test func hInsideAFolderJumpsToThatFolder() throws {
        let root = try makeTree(["src/a.swift", "src/b.swift"])
        var browser = FileBrowser(root: root)
        _ = browser.type("ljj")
        #expect(browser.selectedName == "b.swift")

        _ = browser.type("h")

        #expect(browser.selectedName == "src")
        #expect(browser.outline == ["src/", "  a.swift", "  b.swift"])
    }

    @Test func enterTogglesAFolder() throws {
        let root = try makeTree(["src/main.swift"])
        var browser = FileBrowser(root: root)

        _ = browser.handle(.enter, pageHeight: 20)
        #expect(browser.outline == ["src/", "  main.swift"])

        _ = browser.handle(.enter, pageHeight: 20)
        #expect(browser.outline == ["src/"])
    }

    @Test func dashGoesUpAFolderAndKeepsYourPlace() throws {
        let parent = try makeTree(["project/README.md", "other/"])
        var browser = FileBrowser(root: "\(parent)/project")

        _ = browser.type("-")

        #expect(browser.root == parent)
        #expect(browser.outline == ["other/", "project/", "  README.md"])
        #expect(browser.selectedName == "project")
    }

    @Test func revealOpensTheFoldersDownToAFileAndSelectsIt() throws {
        let root = try makeTree(["Sources/Scwrote/AppDelegate.swift", "Sources/Core/x.swift", "README.md"])
        var browser = FileBrowser(root: root)

        browser.reveal("\(root)/Sources/Scwrote/AppDelegate.swift")

        #expect(browser.outline == [
            "Sources/", "  Core/", "  Scwrote/", "    AppDelegate.swift", "README.md",
        ])
        #expect(browser.selectedName == "AppDelegate.swift")
    }

    /// nvim reports real paths (/private/var/...), while the browser's root may
    /// be reached through a symlink (/var/... and /tmp are symlinks on macOS).
    /// A symlink to a file is its own row, not the row of the file it points to.
    @Test func revealKeepsASymlinkItemsOwnRow() throws {
        let root = try makeTree(["a.md"])
        try FileManager.default.createSymbolicLink(atPath: "\(root)/l.md", withDestinationPath: "\(root)/a.md")
        var browser = FileBrowser(root: root)

        browser.reveal("\(root)/l.md")

        #expect(browser.selectedName == "l.md")
        #expect(browser.selectedPath == "\(root)/l.md")
    }

    @Test func revealMatchesAFileReachedThroughASymlinkedFolder() throws {
        let root = try makeTree(["docs/guide.md"])
        #expect(root.hasPrefix("/var/"), "the temp folder should be under the /var symlink")
        var browser = FileBrowser(root: root)

        browser.reveal("/private\(root)/docs/guide.md")

        #expect(browser.selectedPath == "\(root)/docs/guide.md")
    }
}

struct FileBrowserActionTests {
    @Test func enterOAndLOpenAFile() throws {
        let root = try makeTree(["README.md"])
        var browser = FileBrowser(root: root)

        #expect(browser.handle(.enter, pageHeight: 20) == .open("\(root)/README.md"))
        #expect(browser.type("o") == .open("\(root)/README.md"))
        #expect(browser.type("l") == .open("\(root)/README.md"))
    }

    @Test func escapeLeavesTheBrowser() throws {
        let root = try makeTree(["README.md"])
        var browser = FileBrowser(root: root)

        #expect(browser.handle(.escape, pageHeight: 20) == .leave)
    }

    @Test func clickingARowSelectsItAndOutOfRangeRowsAreIgnored() throws {
        let root = try makeTree(["a.md", "b.md", "c.md"])
        var browser = FileBrowser(root: root)

        browser.select(row: 2)
        #expect(browser.selectedName == "c.md")

        browser.select(row: 7)
        #expect(browser.selectedName == "c.md")
    }

    @Test func movingReportsNoAction() throws {
        let root = try makeTree(["a.md", "b.md"])
        var browser = FileBrowser(root: root)

        #expect(browser.type("j") == nil)
    }

    @Test func aAsksToAdd() throws {
        let root = try makeTree(["a.md"])
        var browser = FileBrowser(root: root)

        #expect(browser.type("a") == .add)
        #expect(browser.type("3a") == .add)
    }

    @Test func aAsksToAddInAnEmptyFolder() throws {
        let root = try makeTree([])
        var browser = FileBrowser(root: root)

        #expect(browser.type("a") == .add)
    }

    @Test func rAndDActOnTheSelection() throws {
        let root = try makeTree(["a.md", "b.md"])
        var browser = FileBrowser(root: root)
        _ = browser.type("j")

        #expect(browser.selectedEntry == FileEntry(name: "b.md", path: "\(root)/b.md", isDirectory: false))
        #expect(browser.type("r") == .rename("\(root)/b.md"))
        #expect(browser.type("d") == .delete("\(root)/b.md"))
        // A count before them means nothing and doesn't move the selection.
        #expect(browser.type("2d") == .delete("\(root)/b.md"))
    }

    @Test func rAndDDoNothingInAnEmptyFolder() throws {
        let root = try makeTree([])
        var browser = FileBrowser(root: root)

        #expect(browser.selectedEntry == nil)
        #expect(browser.type("r") == nil)
        #expect(browser.type("d") == nil)
    }
}

struct FileBrowserNvimPathTests {
    @Test func resolvesTheFoldersAboveTheItem() throws {
        let root = try makeTree(["a.md"])
        #expect(root.hasPrefix("/var/"), "the temp folder should be under the /var symlink")

        #expect(FileBrowser.nvimPath(of: "\(root)/a.md") == "/private\(root)/a.md")
    }

    @Test func followsASymlinkedFolderInsideTheRoot() throws {
        let root = try makeTree(["elsewhere/x.md"])
        try FileManager.default.createSymbolicLink(atPath: "\(root)/linkdir", withDestinationPath: "\(root)/elsewhere")

        #expect(FileBrowser.nvimPath(of: "\(root)/linkdir/x.md") == "/private\(root)/elsewhere/x.md")
    }

    @Test func keepsASymlinkItemsOwnName() throws {
        let root = try makeTree(["x.md"])
        try FileManager.default.createSymbolicLink(atPath: "\(root)/link.md", withDestinationPath: "\(root)/x.md")

        #expect(FileBrowser.nvimPath(of: "\(root)/link.md") == "/private\(root)/link.md")
    }

    @Test func aSymlinkedFolderRowIsNamedByItsTargetSoFilesInsideAreSeen() throws {
        let root = try makeTree(["elsewhere/x.md"])
        try FileManager.default.createSymbolicLink(atPath: "\(root)/linkdir", withDestinationPath: "\(root)/elsewhere")

        let row = FileBrowser.nvimPath(of: "\(root)/linkdir", isDirectory: true)
        #expect(row == "/private\(root)/elsewhere")
        #expect(FileBrowser.nvimPath(of: "\(root)/x.md", isDirectory: false) == "/private\(root)/x.md")
        #expect(FileBrowser.nvimPath(of: "\(root)/linkdir", isDirectory: false) == "/private\(root)/linkdir")
        var unsaved = UnsavedFiles()
        unsaved.apply(.modified(path: "/private\(root)/elsewhere/x.md", isModified: true))
        #expect(unsaved.marks(row, isDirectory: true))
    }

    @Test func worksForAnItemThatIsGone() throws {
        let root = try makeTree([])

        #expect(FileBrowser.nvimPath(of: "\(root)/gone.md") == "/private\(root)/gone.md")
    }
}

struct FileBrowserRestoreTests {
    @Test func expandedFoldersRoundTrip() throws {
        let root = try makeTree(["a/b/f.md", "c/"])
        var browser = FileBrowser(root: root)
        browser.reveal("\(root)/a/b/f.md")

        #expect(browser.expandedFolders == ["\(root)/a", "\(root)/a/b"])

        var fresh = FileBrowser(root: root)
        fresh.restore(expanded: browser.expandedFolders, selected: browser.selectedPath)

        #expect(fresh.outline == browser.outline)
        #expect(fresh.selectedPath == "\(root)/a/b/f.md")
    }

    @Test func vanishedPathsAreDropped() throws {
        let root = try makeTree(["a/x.md"])
        var browser = FileBrowser(root: root)

        browser.restore(expanded: ["\(root)/a", "\(root)/gone"], selected: "\(root)/gone/x")

        #expect(browser.expandedFolders == ["\(root)/a"])
        #expect(browser.cursor == 0)
    }
}
