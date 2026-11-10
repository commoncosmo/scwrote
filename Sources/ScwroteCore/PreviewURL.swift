import Foundation

/// The URLs the preview's web view loads. `scwrote-file` serves files from
/// disk and `scwrote-app` serves the renderer shipped in the app bundle.
public enum PreviewURL {
    public static let fileScheme = "scwrote-file"
    public static let appScheme = "scwrote-app"

    /// `scwrote-file:///abs/path`, percent-encoded.
    public static func file(_ path: String) -> URL {
        url(path: path)
    }

    /// The file's folder with a trailing slash, for `<base href>`, so relative
    /// references in the document resolve next to it.
    public static func folder(of path: String) -> URL {
        var folder = (path as NSString).deletingLastPathComponent
        if !folder.hasSuffix("/") { folder += "/" }
        return url(path: folder)
    }

    /// The file path a `scwrote-file` URL points at; nil for other schemes,
    /// and for one with a host: a protocol-relative `//host/x` in a document
    /// resolves to that, and it names something on the network, not a file.
    public static func path(from url: URL) -> String? {
        guard url.scheme == fileScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.host?.isEmpty ?? true
        else { return nil }
        return components.path
    }

    public static let appIndex = URL(string: "\(appScheme):///index.html")!

    private static func url(path: String) -> URL {
        var components = URLComponents()
        components.scheme = fileScheme
        components.host = ""
        components.path = path
        return components.url!
    }
}
