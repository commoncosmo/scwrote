import Foundation
import Testing
@testable import ScwroteCore

struct PreviewURLTests {
    @Test(arguments: ["/a/b.md", "/my notes/it's #1 100%?.md", "/ü/é.png"])
    func pathsRoundTrip(path: String) {
        #expect(PreviewURL.path(from: PreviewURL.file(path)) == path)
    }

    @Test func relativeReferencesResolveAgainstTheFolder() {
        let base = PreviewURL.folder(of: "/my notes/doc #1.md")
        #expect(PreviewURL.path(from: URL(string: "img/a%20b.png", relativeTo: base)!) == "/my notes/img/a b.png")
    }

    @Test func otherSchemesAreNotFiles() {
        #expect(PreviewURL.path(from: URL(string: "https://example.com/a.md")!) == nil)
    }

    /// `//cdn.example.com/a.css` in a document resolves to a `scwrote-file`
    /// URL with a host: a remote reference, never a file on disk.
    @Test func aFileURLWithAHostIsNotAFile() {
        #expect(PreviewURL.path(from: URL(string: "scwrote-file://cdn.example.com/a.css")!) == nil)
        let base = PreviewURL.folder(of: "/n/page.html")
        #expect(PreviewURL.path(from: URL(string: "//cdn.example.com/a.css", relativeTo: base)!) == nil)
    }
}
