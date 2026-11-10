import Testing
@testable import ScwroteCore

struct PreviewAutocommandsTests {
    @Test func whichFilesGetTheirTextComesFromPreviewKind() throws {
        let arguments = PreviewAutocommands.arguments(channel: 3, sendsText: true)

        #expect(arguments.count == 3)
        #expect(arguments[0] == .int(3) && arguments[1] == .bool(true))
        guard case let .map(previewable) = arguments[2],
              case let .map(extensions)? = previewable[.string("extensions")],
              case let .map(filetypes)? = previewable[.string("filetypes")]
        else {
            Issue.record("no extensions and filetypes")
            return
        }
        // Every extension PreviewKind knows, so a known one that needs no text
        // (an image) isn't decided by its filetype instead.
        #expect(extensions.count == PreviewKind.byExtension.count)
        #expect(extensions[.string("md")] == .bool(true))
        #expect(extensions[.string("png")] == .bool(false))
        #expect(filetypes[.string("markdown")] == .bool(true))
        #expect(filetypes.count == PreviewKind.byFiletype.count)
    }
}
