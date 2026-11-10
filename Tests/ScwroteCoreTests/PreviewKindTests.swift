import Testing
@testable import ScwroteCore

struct PreviewKindTests {
    @Test(arguments: [
        ("a.md", PreviewKind.markdown), ("a.markdown", .markdown), ("A.MD", .markdown),
        ("d.csv", .csv), ("d.tsv", .tsv), ("d.tab", .tsv),
        ("p.html", .html), ("p.htm", .html), ("g.mmd", .mermaid), ("g.mermaid", .mermaid),
        ("i.svg", .svg), ("c.json", .json), ("c.jsonc", .json), ("c.yaml", .yaml), ("c.yml", .yaml),
        ("x.png", .image), ("x.jpg", .image), ("x.jpeg", .image), ("x.gif", .image),
        ("x.webp", .image), ("x.heic", .image), ("x.tiff", .image), ("x.pdf", .pdf),
        ("Main.swift", .unsupported), ("Makefile", .unsupported),
    ])
    func kindFromExtension(path: String, kind: PreviewKind) {
        #expect(PreviewKind(path: "/tmp/\(path)") == kind)
    }

    @Test func filetypeDecidesWhenTheExtensionDoesNot() {
        #expect(PreviewKind(path: "/tmp/NOTES", filetype: "markdown") == .markdown)
        #expect(PreviewKind(path: "/tmp/.prettierrc", filetype: "json") == .json)
        #expect(PreviewKind(path: "/tmp/x.txt", filetype: "text") == .unsupported)
    }

    @Test func extensionWinsOverFiletype() {
        #expect(PreviewKind(path: "/tmp/a.csv", filetype: "text") == .csv)
    }

    @Test func viewOnlyAndPageKinds() {
        #expect(PreviewKind.image.isViewOnly && PreviewKind.pdf.isViewOnly)
        #expect(!PreviewKind.svg.isViewOnly)
        #expect(PreviewKind.markdown.rendersInPage && !PreviewKind.html.rendersInPage && !PreviewKind.pdf.rendersInPage)
        #expect(PreviewKind.unsupported.displayName == "no preview")
    }
}
