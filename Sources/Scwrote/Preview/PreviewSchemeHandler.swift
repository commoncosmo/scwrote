import Foundation
import ScwroteCore
import UniformTypeIdentifiers
import WebKit

/// Serves the preview's two URL schemes: `scwrote-app` from the renderer page
/// shipped in the app bundle, and `scwrote-file` from disk, with the shown
/// buffer's unsaved text standing in for its file. Files are read off the
/// main thread. Both preview web views share one handler.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let appResources: URL
    /// The shown buffer's unsaved text, served in place of the file at `path`.
    var overlay: (path: String, text: String)?
    /// Tasks waiting for a file read; a stopped task is removed and never
    /// answered. Each start gets its own token: a stopped task's identifier
    /// can be reused by a new task, which must not get the old one's file.
    private var reading: [ObjectIdentifier: (token: Int, task: any WKURLSchemeTask)] = [:]
    private var nextToken = 0

    init(appResources: URL) {
        self.appResources = appResources.standardizedFileURL
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if let overlay, PreviewURL.path(from: url) == overlay.path {
            Self.respond(task, url: url, data: Data(overlay.text.utf8), mimeType: Self.mimeType(of: overlay.path), isUTF8: true)
            return
        }
        guard let file = file(for: url) else {
            Self.respondNotFound(task, url: url)
            return
        }
        let id = ObjectIdentifier(task)
        nextToken += 1
        let token = nextToken
        reading[id] = (token, task)
        let isApp = url.scheme == PreviewURL.appScheme
        Task {
            let data = await Self.read(file)
            guard let waiting = reading[id], waiting.token == token else { return }
            reading[id] = nil
            let task = waiting.task
            if let data {
                // The renderer's own text files are UTF-8; user files say for themselves.
                Self.respond(task, url: url, data: data, mimeType: Self.mimeType(of: file.path), isUTF8: isApp)
            } else {
                Self.respondNotFound(task, url: url)
            }
        }
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        reading[ObjectIdentifier(task)] = nil
    }

    /// The file a URL names: under the app's resources for `scwrote-app`
    /// (never outside them), or the path itself for `scwrote-file` (never
    /// one with a host, which names something on the network).
    private func file(for url: URL) -> URL? {
        switch url.scheme {
        case PreviewURL.appScheme:
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path else { return nil }
            let file = appResources.appending(path: path).standardizedFileURL
            return file.path.hasPrefix(appResources.path + "/") ? file : nil
        case PreviewURL.fileScheme:
            return PreviewURL.path(from: url).map { URL(fileURLWithPath: $0) }
        default:
            return nil
        }
    }

    /// The file's contents, if it is a regular file (or a link to one):
    /// never a device, a pipe or a folder, which could block or never end.
    @concurrent
    private nonisolated static func read(_ file: URL) async -> Data? {
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? Data(contentsOf: file)
    }

    private static func mimeType(of path: String) -> String {
        UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String, isUTF8: Bool) {
        let isText = mimeType.hasPrefix("text/") || mimeType.hasSuffix("javascript") || mimeType.hasSuffix("json")
        let contentType = isUTF8 && isText ? "\(mimeType); charset=utf-8" : mimeType
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            // Files change on disk while shown; never reuse an old copy.
            "Cache-Control": "no-cache",
            // No DNS lookups for links in a page, which would reach the
            // network even with remote content blocked.
            "X-DNS-Prefetch-Control": "off",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    private static func respondNotFound(_ task: any WKURLSchemeTask, url: URL) {
        task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
        task.didFinish()
    }
}
