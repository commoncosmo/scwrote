import Foundation
import Testing

@testable import ScwroteCore

/// A project folder with a stand-in Trash beside it, so no test touches the
/// user's real Trash. Both are removed when the helper goes away.
private final class TempFolder {
    let base: String
    let root: String
    let trash: String
    let fileSystem: LocalFileSystem
    let actions: FileActions

    init() throws {
        base = FileManager.default.temporaryDirectory.path + "/scwrote-actions-" + UUID().uuidString
        root = base + "/proj"
        trash = base + "/trash"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        fileSystem = LocalFileSystem(trashFolder: trash)
        actions = FileActions(root: root, fileSystem: fileSystem)
    }

    deinit { try? FileManager.default.removeItem(atPath: base) }

    func write(_ relative: String, _ text: String = "") throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/" + relative)
    }

    func listing(_ relative: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + relative)) ?? []).sorted()
    }
}

private extension Result where Failure == FileActionError {
    var failureMessage: String? {
        if case .failure(let error) = self { error.message } else { nil }
    }
}

private func fail(_ message: String) -> Result<NewItem, FileActionError> {
    .failure(FileActionError(message: message))
}

@Suite struct FileActionsTests {
    @Test func folderForNewItemFollowsTheSelection() throws {
        let t = try TempFolder()
        let folder = FileEntry(name: "notes", path: "/r/notes", isDirectory: true)
        let file = FileEntry(name: "a.md", path: "/r/notes/a.md", isDirectory: false)
        #expect(t.actions.folderForNewItem(selected: folder) == "/r/notes")
        #expect(t.actions.folderForNewItem(selected: file) == "/r/notes")
        #expect(t.actions.folderForNewItem(selected: nil) == t.root)
    }

    @Test func createsAFileAndItsFolders() throws {
        let t = try TempFolder()
        let result = t.actions.create("notes/today.md", in: t.root)
        #expect(result == .success(NewItem(path: t.root + "/notes/today.md", isFolder: false)))
        #expect(try String(contentsOfFile: t.root + "/notes/today.md", encoding: .utf8) == "")
    }

    @Test func aTrailingSlashMakesAFolder() throws {
        let t = try TempFolder()
        let result = t.actions.create("drafts/", in: t.root)
        #expect(result == .success(NewItem(path: t.root + "/drafts", isFolder: true)))
        #expect(t.fileSystem.isFolder(at: t.root + "/drafts"))
    }

    @Test func existingNamesAreRefused() throws {
        let t = try TempFolder()
        try t.write("a.md", "keep")
        #expect(t.actions.create("a.md", in: t.root) == fail("a.md already exists"))
        #expect(try String(contentsOfFile: t.root + "/a.md", encoding: .utf8) == "keep")
        try t.write("sub/b.md")
        #expect(t.actions.create("sub/b.md", in: t.root) == fail("sub/b.md already exists"))
        #expect(t.actions.create("sub/", in: t.root) == fail("sub already exists"))
    }

    @Test func emptyNamesAreRefused() throws {
        let t = try TempFolder()
        #expect(t.actions.create("", in: t.root) == fail("name can't be empty"))
        #expect(t.actions.create("/", in: t.root) == fail("name can't be empty"))
    }

    @Test func namesThatLeaveTheRootAreRefused() throws {
        let t = try TempFolder()
        for name in ["../x", "/etc/x", "a/../../x", "."] {
            #expect(t.actions.create(name, in: t.root) == fail("can't leave proj/"))
        }
        #expect(t.listing() == [])
        #expect(t.listing("..").sorted() == ["proj", "trash"])
    }

    @Test func dotDotInsideTheRootIsResolved() throws {
        let t = try TempFolder()
        try t.write("sub/keep.md")
        let result = t.actions.create("../x.md", in: t.root + "/sub")
        #expect(result == .success(NewItem(path: t.root + "/x.md", isFolder: false)))
    }

    @Test func unusualNamesWork() throws {
        let t = try TempFolder()
        for name in [".env", "my notes.md", "über.md"] {
            #expect(t.actions.create(name, in: t.root) == .success(NewItem(path: t.root + "/" + name, isFolder: false)))
        }
        #expect(t.actions.rename(t.root + "/my notes.md", to: "über 2.md") == .success(t.root + "/über 2.md"))
        #expect(t.exists("über 2.md"))
    }

    @Test func renameMovesWithinTheRoot() throws {
        let t = try TempFolder()
        try t.write("a.md", "x")
        #expect(t.actions.rename(t.root + "/a.md", to: "sub/b.md") == .success(t.root + "/sub/b.md"))
        #expect(!t.exists("a.md"))
        #expect(t.exists("sub/b.md"))
    }

    @Test func renameCannotLeaveTheRoot() throws {
        let t = try TempFolder()
        try t.write("a.md")
        #expect(t.actions.rename(t.root + "/a.md", to: "../a.md") == .failure(FileActionError(message: "can't leave proj/")))
        #expect(t.exists("a.md"))
    }

    @Test func renameToTheSameNameDoesNothing() throws {
        let t = try TempFolder()
        try t.write("a.md")
        #expect(t.actions.rename(t.root + "/a.md", to: "a.md") == .success(nil))
    }

    @Test func renameChangesOnlyTheCase() throws {
        let t = try TempFolder()
        try t.write("Notes.md", "x")
        #expect(t.actions.rename(t.root + "/Notes.md", to: "notes.md") == .success(t.root + "/notes.md"))
        #expect(t.listing() == ["notes.md"])
    }

    @Test func renameOntoAnExistingNameIsRefused() throws {
        let t = try TempFolder()
        try t.write("a.md", "a")
        try t.write("b.md", "b")
        #expect(t.actions.rename(t.root + "/a.md", to: "b.md") == .failure(FileActionError(message: "b.md already exists")))
        #expect(try String(contentsOfFile: t.root + "/b.md", encoding: .utf8) == "b")
        #expect(t.exists("a.md"))
    }

    @Test func actingOnAMissingItemSaysSo() throws {
        let t = try TempFolder()
        let gone = t.root + "/a.md"
        #expect(t.actions.rename(gone, to: "b.md") == .failure(FileActionError(message: "a.md no longer exists")))
        #expect(t.actions.delete(gone).failureMessage == "a.md no longer exists")
    }

    @Test func deleteGoesToTheTrash() throws {
        let t = try TempFolder()
        try t.write("a.md")
        try t.write("d/x.md")
        #expect(t.actions.delete(t.root + "/a.md").failureMessage == nil)
        #expect(t.actions.delete(t.root + "/d").failureMessage == nil)
        #expect(t.listing() == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.trash).sorted() == ["a.md", "d"])
    }

    @Test func deleteQuestions() throws {
        let t = try TempFolder()
        try t.write("notes.md")
        for i in 0..<12 { try t.write("drafts/f\(i).md") }
        try t.write("one/x.md")
        try FileManager.default.createDirectory(atPath: t.root + "/zero", withIntermediateDirectories: true)
        let q = { (p: String, u: Bool) in t.actions.deleteQuestion(for: p, hasUnsavedChanges: u) }
        #expect(q(t.root + "/notes.md", false) == "Delete notes.md? (y/N)")
        #expect(q(t.root + "/drafts", false) == "Delete folder drafts/ and its 12 items? (y/N)")
        #expect(q(t.root + "/one", false) == "Delete folder one/ and its 1 item? (y/N)")
        #expect(q(t.root + "/zero", false) == "Delete folder zero/ and its 0 items? (y/N)")
        #expect(q(t.root + "/notes.md", true) == "notes.md has unsaved changes. Delete anyway? (y/N)")
        #expect(q(t.root + "/drafts", true) == "drafts/ has unsaved changes. Delete anyway? (y/N)")
    }

    @Test func aHardLinkIsAClashNotARename() throws {
        let t = try TempFolder()
        try t.write("h1.md", "x")
        try FileManager.default.linkItem(atPath: t.root + "/h1.md", toPath: t.root + "/h2.md")
        #expect(t.actions.rename(t.root + "/h1.md", to: "h2.md") == .failure(FileActionError(message: "h2.md already exists")))
        #expect(t.listing() == ["h1.md", "h2.md"])
    }

    @Test func aFailedCaseRenamePutsTheItemBack() throws {
        let t = try TempFolder()
        try t.write("Notes.md", "x")
        let stub = FailingSecondMove(wrapping: t.fileSystem)
        let actions = FileActions(root: t.root, fileSystem: stub)
        let result = actions.rename(t.root + "/Notes.md", to: "notes.md")
        #expect(result.failureMessage != nil)
        #expect(t.listing() == ["Notes.md"])
    }

    @Test func theRootAndItsAliasesCannotBeDeleted() throws {
        let t = try TempFolder()
        try t.write("sub/a.md")
        for path in [t.root, t.root + "/", t.root + "/.", t.root + "/sub/.."] {
            #expect(t.actions.delete(path).failureMessage == "can't leave proj/")
        }
        #expect(t.exists("sub/a.md"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.trash) == [])
        #expect(t.actions.rename(t.root, to: "x").failureMessage == "can't leave proj/")
    }

    @Test func aFolderCannotMoveIntoItself() throws {
        let t = try TempFolder()
        try t.write("a/f.md")
        for name in ["a/b", "a/x/b"] {
            #expect(t.actions.rename(t.root + "/a", to: name).failureMessage == "can't move a folder into itself")
        }
        #expect(t.listing("a") == ["f.md"])
    }

    @Test func aFailedMoveLeavesNoStrayFolders() throws {
        let t = try TempFolder()
        try t.write("a.md")
        try t.write("blocker", "file")
        // The parent "blocker" is a file, so making x/y under it must fail cleanly.
        _ = t.actions.rename(t.root + "/a.md", to: "blocker/x/b.md")
        #expect(t.listing() == ["a.md", "blocker"])
        // A move that fails after parents were made: destination folder exists as a file elsewhere.
        let fs = t.fileSystem
        #expect((try? fs.moveItem(at: t.root + "/missing", to: t.root + "/p/q/r")) == nil)
        #expect(!t.exists("p"))
    }

    @Test func aSymlinkInsideTheRootIsFollowed() throws {
        let t = try TempFolder()
        let outside = t.base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: t.root + "/link", withDestinationPath: outside)
        let result = t.actions.create("link/x.md", in: t.root)
        #expect(result == .success(NewItem(path: t.root + "/link/x.md", isFolder: false)))
        #expect(FileManager.default.fileExists(atPath: outside + "/x.md"))
    }
}

/// Wraps a real file system but fails the second `moveItem`, to exercise the
/// rollback of a case-only rename.
private final class FailingSecondMove: FileSystem, @unchecked Sendable {
    private let inner: any FileSystem
    private let lock = NSLock()
    private var moves = 0

    init(wrapping inner: any FileSystem) { self.inner = inner }

    func itemExists(at path: String) -> Bool { inner.itemExists(at: path) }
    func isFolder(at path: String) -> Bool { inner.isFolder(at: path) }
    func isSameItem(_ a: String, _ b: String) -> Bool { inner.isSameItem(a, b) }
    func createFile(at path: String) throws { try inner.createFile(at: path) }
    func createFolder(at path: String) throws { try inner.createFolder(at: path) }
    func trashItem(at path: String) throws { try inner.trashItem(at: path) }
    func itemCount(inFolder path: String) -> Int { inner.itemCount(inFolder: path) }

    func moveItem(at source: String, to destination: String) throws {
        lock.lock()
        moves += 1
        let n = moves
        lock.unlock()
        if n == 2 { throw CocoaError(.fileWriteUnknown) }
        try inner.moveItem(at: source, to: destination)
    }
}
