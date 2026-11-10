import Testing
@testable import ScwroteCore

struct PreviewEventInboxTests {
    private func buffer(_ path: String, _ text: String, line: Int = 1) -> PreviewEvent {
        .buffer(BufferSnapshot(
            path: path, filetype: "", text: text, isModified: false, cursor: CursorPosition(line: line, column: 0)
        ))
    }

    private func cursor(_ path: String, line: Int) -> PreviewEvent {
        .cursor(path: path, CursorPosition(line: line, column: 0))
    }

    @Test func onlyTheFirstPostAsksForADelivery() {
        let inbox = PreviewEventInbox()

        #expect(inbox.post(cursor("/a.md", line: 1)))
        #expect(!inbox.post(cursor("/a.md", line: 2)))
        #expect(inbox.take() == [cursor("/a.md", line: 1), cursor("/a.md", line: 2)])
        #expect(inbox.take().isEmpty)
        #expect(inbox.post(cursor("/a.md", line: 3)))
    }

    /// Rendering a big file costs; when edits come faster than that, only the
    /// newest text is worth drawing.
    @Test func aNewerBufferForTheSameFileReplacesAWaitingOne() {
        let inbox = PreviewEventInbox()

        _ = inbox.post(buffer("/a.md", "one", line: 1))
        _ = inbox.post(cursor("/a.md", line: 2))
        _ = inbox.post(.modified(path: "/a.md", isModified: true))
        _ = inbox.post(buffer("/a.md", "two", line: 2))
        _ = inbox.post(cursor("/a.md", line: 3))

        // Everything else keeps its order; the newest text comes where it was sent.
        #expect(inbox.take() == [
            cursor("/a.md", line: 2),
            .modified(path: "/a.md", isModified: true),
            buffer("/a.md", "two", line: 2),
            cursor("/a.md", line: 3),
        ])
    }

    @Test func buffersForOtherFilesAreKept() {
        let inbox = PreviewEventInbox()

        _ = inbox.post(buffer("/a.md", "a"))
        _ = inbox.post(buffer("/b.md", "b"))

        #expect(inbox.take() == [buffer("/a.md", "a"), buffer("/b.md", "b")])
    }
}
