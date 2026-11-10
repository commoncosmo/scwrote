import Testing
@testable import ScwroteCore

struct PreviewEventTests {
    /// The one param of a `scwrote_preview` notification: a map keyed by strings.
    private func params(_ fields: [String: MessagePackValue]) -> [MessagePackValue] {
        [.map(Dictionary(uniqueKeysWithValues: fields.map { (MessagePackValue.string($0.key), $0.value) }))]
    }

    private let bufferFields: [String: MessagePackValue] = [
        "type": .string("buffer"),
        "path": .string("/notes/a.md"),
        "filetype": .string("markdown"),
        "modified": .bool(true),
        "text": .string("# hi\nthere"),
        "line": .int(2),
        "column": .int(3),
    ]

    @Test func aBufferWithEveryFieldDecodes() {
        let event = PreviewEvent(method: "scwrote_preview", params: params(bufferFields))

        #expect(event == .buffer(BufferSnapshot(
            path: "/notes/a.md", filetype: "markdown", text: "# hi\nthere",
            isModified: true, cursor: CursorPosition(line: 2, column: 3)
        )))
    }

    @Test func aBufferWithoutTextHasNilText() {
        var fields = bufferFields
        fields["text"] = nil

        let event = PreviewEvent(method: "scwrote_preview", params: params(fields))

        #expect(event == .buffer(BufferSnapshot(
            path: "/notes/a.md", filetype: "markdown", text: nil,
            isModified: true, cursor: CursorPosition(line: 2, column: 3)
        )))
    }

    @Test func textLeftOutBecauseNobodyAskedSaysSo() {
        var fields = bufferFields
        fields["text"] = nil
        fields["omitted"] = .string("not_requested")

        guard case let .buffer(snapshot)? = PreviewEvent(method: "scwrote_preview", params: params(fields)) else {
            Issue.record("not a buffer event")
            return
        }
        #expect(snapshot.text == nil && snapshot.textOmission == .notRequested)
    }

    @Test func textLeftOutForSizeIsTooLarge() {
        var fields = bufferFields
        fields["text"] = nil
        fields["omitted"] = .string("too_large")

        guard case let .buffer(snapshot)? = PreviewEvent(method: "scwrote_preview", params: params(fields)) else {
            Issue.record("not a buffer event")
            return
        }
        #expect(snapshot.textOmission == .tooLarge)
    }

    @Test func unsavedDecodesTheWholeSet() {
        let event = PreviewEvent(method: "scwrote_preview", params: params([
            "type": .string("unsaved"), "paths": .array([.string("/a.md"), .string("/b.md")]),
        ]))
        #expect(event == .unsaved(["/a.md", "/b.md"]))
    }

    @Test func anEmptyUnsavedSetDecodesFromAnArrayOrAMap() {
        for empty in [MessagePackValue.array([]), .map([:])] {
            let event = PreviewEvent(method: "scwrote_preview", params: params([
                "type": .string("unsaved"), "paths": empty,
            ]))
            #expect(event == .unsaved([]))
        }
    }

    @Test func unsavedWithBadPathsIsIgnored() {
        #expect(PreviewEvent(method: "scwrote_preview", params: params([
            "type": .string("unsaved"), "paths": .array([.int(3)]),
        ])) == nil)
        #expect(PreviewEvent(method: "scwrote_preview", params: params(["type": .string("unsaved")])) == nil)
    }

    @Test func modifiedDecodes() {
        let event = PreviewEvent(method: "scwrote_preview", params: params([
            "type": .string("modified"), "path": .string("/notes/a.md"), "modified": .bool(false),
        ]))

        #expect(event == .modified(path: "/notes/a.md", isModified: false))
    }

    @Test func cursorDecodes() {
        let event = PreviewEvent(method: "scwrote_preview", params: params([
            "type": .string("cursor"), "path": .string("/notes/a.md"), "line": .int(7), "column": .int(0),
        ]))

        #expect(event == .cursor(path: "/notes/a.md", CursorPosition(line: 7, column: 0)))
    }

    @Test func anotherMethodIsIgnored() {
        #expect(PreviewEvent(method: "nvim_buf_lines_event", params: params(bufferFields)) == nil)
    }

    @Test func anUnknownTypeIsIgnored() {
        var fields = bufferFields
        fields["type"] = .string("selection")

        #expect(PreviewEvent(method: "scwrote_preview", params: params(fields)) == nil)
    }

    @Test func aMissingPathIsIgnored() {
        var fields = bufferFields
        fields["path"] = nil

        #expect(PreviewEvent(method: "scwrote_preview", params: params(fields)) == nil)
    }

    @Test func paramsThatAreNotAMapAreIgnored() {
        #expect(PreviewEvent(method: "scwrote_preview", params: []) == nil)
        #expect(PreviewEvent(method: "scwrote_preview", params: [.string("buffer")]) == nil)
    }
}

struct BufferSnapshotLineCountTests {
    private func snapshot(_ text: String?) -> BufferSnapshot {
        BufferSnapshot(path: "/a.html", filetype: "html", text: text, isModified: false, cursor: CursorPosition(line: 1, column: 0))
    }

    @Test func linesAreJoinedByNewlinesWithoutATrailingOne() {
        #expect(snapshot("a\nb\nc").lineCount == 3)
    }

    @Test func anEmptyBufferHasOneLine() {
        #expect(snapshot("").lineCount == 1)
    }

    @Test func aBlankLastLineCounts() {
        #expect(snapshot("a\n").lineCount == 2)
    }

    @Test func crlfCountsAsOneLineBreak() {
        #expect(snapshot("a\r\nb").lineCount == 2)
    }

    @Test func aBufferTooLargeToSendCountsAsOneLine() {
        #expect(snapshot(nil).lineCount == 1)
    }
}
