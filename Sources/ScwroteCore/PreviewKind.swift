/// What the preview pane shows for a file, decided from its extension and,
/// when the extension says nothing, nvim's `filetype`.
public enum PreviewKind: String, Equatable, Sendable {
    case markdown, csv, tsv, html, mermaid, svg, json, yaml, image, pdf, unsupported

    static let byExtension: [String: PreviewKind] = [
        "md": .markdown, "markdown": .markdown,
        "csv": .csv,
        "tsv": .tsv, "tab": .tsv,
        "html": .html, "htm": .html,
        "mmd": .mermaid, "mermaid": .mermaid,
        "svg": .svg,
        "json": .json, "jsonc": .json,
        "yaml": .yaml, "yml": .yaml,
        "pdf": .pdf,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image,
        "heic": .image, "heif": .image, "tiff": .image, "tif": .image,
        "bmp": .image, "ico": .image,
    ]

    /// nvim's `filetype` values that map to a kind.
    static let byFiletype: [String: PreviewKind] = [
        "markdown": .markdown, "csv": .csv, "tsv": .tsv, "html": .html,
        "mermaid": .mermaid, "svg": .svg, "json": .json, "jsonc": .json,
        "yaml": .yaml,
    ]

    public init(path: String, filetype: String? = nil) {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        var fromExtension: PreviewKind?
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            fromExtension = Self.byExtension[ext]
        }
        self = fromExtension
            ?? filetype.flatMap { Self.byFiletype[$0] }
            ?? .unsupported
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .html: "HTML"
        case .mermaid: "Mermaid"
        case .svg: "SVG"
        case .json: "JSON"
        case .yaml: "YAML"
        case .image: "Image"
        case .pdf: "PDF"
        case .unsupported: "no preview"
        }
    }

    /// Kinds drawn from the buffer's text. Images and PDFs are read from disk,
    /// and a file with no preview needs nothing.
    public var needsText: Bool {
        !isViewOnly && self != .unsupported
    }

    /// Images and PDFs are only shown, never interacted with.
    public var isViewOnly: Bool {
        self == .image || self == .pdf
    }

    /// Kinds rendered by scwrote's own renderer scripts. HTML is excluded:
    /// it is shown as static user content, and its scripts never run.
    public var rendersInPage: Bool {
        switch self {
        case .markdown, .csv, .tsv, .mermaid, .svg, .json, .yaml: true
        case .html, .image, .pdf, .unsupported: false
        }
    }
}
