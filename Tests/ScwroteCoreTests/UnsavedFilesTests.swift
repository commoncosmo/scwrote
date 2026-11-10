import Testing
@testable import ScwroteCore

struct UnsavedFilesTests {
    private func snapshot(_ path: String, modified: Bool) -> BufferSnapshot {
        BufferSnapshot(
            path: path, filetype: "", text: nil, textOmission: .notRequested,
            isModified: modified, cursor: CursorPosition(line: 1, column: 0)
        )
    }

    /// `#expect` can't call a mutating method itself.
    private func changed(_ unsaved: inout UnsavedFiles, _ event: PreviewEvent) -> Bool {
        unsaved.apply(event)
    }

    @Test func followsTheModifiedFlag() {
        var unsaved = UnsavedFiles()
        #expect(changed(&unsaved, .modified(path: "/p/a.md", isModified: true)))
        #expect(changed(&unsaved, .buffer(snapshot("/p/b.md", modified: true))))
        #expect(unsaved.count == 2)
        #expect(changed(&unsaved, .modified(path: "/p/a.md", isModified: false)))
        #expect(unsaved.paths == ["/p/b.md"])
    }

    @Test func reportsOnlyRealChanges() {
        var unsaved = UnsavedFiles()
        unsaved.apply(.modified(path: "/p/a.md", isModified: true))
        #expect(!changed(&unsaved, .modified(path: "/p/a.md", isModified: true)))
        #expect(!changed(&unsaved, .buffer(snapshot("/p/a.md", modified: true))))
        #expect(!changed(&unsaved, .modified(path: "/p/other.md", isModified: false)))
        #expect(!changed(&unsaved, .cursor(path: "/p/a.md", CursorPosition(line: 2, column: 0))))
    }

    @Test func marksTheFileAndEveryFolderAboveIt() {
        var unsaved = UnsavedFiles()
        unsaved.apply(.modified(path: "/p/notes/deep/a.md", isModified: true))
        #expect(unsaved.marks("/p/notes/deep/a.md", isDirectory: false))
        #expect(unsaved.marks("/p/notes/deep", isDirectory: true))
        #expect(unsaved.marks("/p/notes", isDirectory: true))
        #expect(unsaved.marks("/p", isDirectory: true))
    }

    @Test func leavesEverythingElseUnmarked() {
        var unsaved = UnsavedFiles()
        unsaved.apply(.modified(path: "/p/notes/a.md", isModified: true))
        #expect(!unsaved.marks("/p/notes/b.md", isDirectory: false))
        #expect(!unsaved.marks("/p/src", isDirectory: true))
        // A folder whose name starts the same isn't a parent.
        #expect(!unsaved.marks("/p/no", isDirectory: true))
        #expect(!unsaved.marks("/p/notes-old", isDirectory: true))
        // A file named like a folder on the path isn't marked.
        #expect(!unsaved.marks("/p/notes", isDirectory: false))
    }

    @Test func nothingUnsavedMarksNothing() {
        #expect(!UnsavedFiles().marks("/p", isDirectory: true))
    }
}
