import Testing
@testable import ScwroteCore

struct PreviewStateTests {
    private func snap(
        _ path: String, _ text: String? = "x", omitted: TextOmission = .tooLarge, modified: Bool = false
    ) -> BufferSnapshot {
        BufferSnapshot(
            path: path, filetype: "", text: text, textOmission: text == nil ? omitted : nil,
            isModified: modified, cursor: .init(line: 1, column: 0)
        )
    }

    @Test func startsWithNoFile() {
        #expect(PreviewState().header == PreviewHeader(label: "No file", isUnsaved: false, message: nil, isError: false))
    }

    @Test func showsTheBufferAndItsUnsavedState() {
        var state = PreviewState()
        #expect(state.apply(.buffer(snap("/n/README.md"))) == .render)
        #expect(state.header.label == "README.md · Markdown" && !state.header.isUnsaved)
        #expect(state.apply(.modified(path: "/n/README.md", isModified: true)) == .headerOnly)
        #expect(state.header.isUnsaved)
        #expect(state.apply(.modified(path: "/n/other.md", isModified: true)) == .nothing)
    }

    @Test func followsTheCursorOfTheShownBufferOnly() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.csv")))
        #expect(state.apply(.cursor(path: "/n/a.csv", .init(line: 3, column: 2))) == .follow(.init(line: 3, column: 2)))
        #expect(state.apply(.cursor(path: "/n/b.csv", .init(line: 1, column: 0))) == .nothing)
    }

    @Test func aPickedImageStaysUntilYouReturnOrSwitchFiles() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.md", modified: true)))
        #expect(state.pickViewOnly("/n/photo.jpg") == .render)
        #expect(state.header.label == "photo.jpg · Image" && !state.header.isUnsaved)
        #expect(state.apply(.buffer(snap("/n/a.md", "new"))) == .nothing)
        #expect(state.returnToEditor() == .render)
        #expect(state.target == .buffer(snap("/n/a.md", "new")))
        _ = state.pickViewOnly("/n/photo.jpg")
        #expect(state.apply(.buffer(snap("/n/b.md"))) == .render)
    }

    @Test func returningWhenAlreadyOnTheBufferChangesNothing() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.md")))
        #expect(state.returnToEditor() == .nothing)
    }

    @Test func errorsAndNotesShowUntilTheNextFile() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.json")))
        state.rendered(error: "line 14: unexpected \"}\"", note: nil)
        #expect(state.header.message == "line 14: unexpected \"}\"" && state.header.isError)
        state.rendered(error: nil, note: "showing 5,000 of 182,340 rows")
        #expect(state.header.message == "showing 5,000 of 182,340 rows" && !state.header.isError)
        _ = state.apply(.buffer(snap("/n/b.json")))
        #expect(state.header.message == nil)
    }

    @Test func unsupportedFilesSayNoPreview() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/Main.swift")))
        #expect(state.header.label == "Main.swift · no preview")
    }

    @Test func tooLargeBufferShowsAMessage() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/big.json", nil)))
        #expect(state.header.message == "too large to preview" && !state.header.isError)
    }

    @Test func textNotAskedForIsNotTooLarge() {
        var state = PreviewState()
        #expect(state.apply(.buffer(snap("/n/a.json", nil, omitted: .notRequested))) == .render)
        #expect(state.header.message == nil)
        #expect(state.header.label == "a.json · JSON")
        #expect(state.isAwaitingText)
    }

    @Test func onlyKindsDrawnFromTextAwaitIt() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/Main.swift", nil, omitted: .notRequested)))
        #expect(!state.isAwaitingText)
        _ = state.apply(.buffer(snap("/n/big.json", nil)))
        #expect(!state.isAwaitingText)
        _ = state.apply(.buffer(snap("/n/a.json")))
        #expect(!state.isAwaitingText)
        _ = state.pickViewOnly("/n/photo.jpg")
        #expect(!state.isAwaitingText)
    }

    @Test func shrinkingBelowTheLimitClearsTheTooLargeMessage() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/big.json", nil)))
        _ = state.apply(.buffer(snap("/n/big.json", "{}")))
        #expect(state.header.message == nil)
    }

    @Test func modifiedFlagOfTheRememberedBufferSurvivesAViewOnlyDetour() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.md")))
        _ = state.pickViewOnly("/n/photo.jpg")
        #expect(state.apply(.modified(path: "/n/a.md", isModified: true)) == .nothing)
        _ = state.returnToEditor()
        #expect(state.header.isUnsaved)
    }
}
