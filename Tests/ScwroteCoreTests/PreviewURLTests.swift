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
}
