import AppKit
import ScwroteCore
import WebKit

/// A preview web view. It loads only what scwrote asks it to, sends clicked
/// links out instead of following them, and leaves the keyboard to the pane.
@MainActor
class PreviewWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    /// A clicked `scwrote-file` link, as a path.
    var onOpenFile: ((String) -> Void)?
    /// Loads started by `loadExpected`, not yet let through. Anything else
    /// (links, forms, scripts, reloads, redirects) is cancelled.
    private var expectedLoads: [URL] = []

    init(configuration: WKWebViewConfiguration, schemeHandler: PreviewSchemeHandler, background: NSColor) {
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.appScheme)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.fileScheme)
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        underPageBackgroundColor = background
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keys go to the pane, which turns them into preview commands.
    override var acceptsFirstResponder: Bool { false }

    func loadExpected(_ url: URL) {
        expectedLoads.append(url)
        load(URLRequest(url: url))
    }

    /// Called when a page scwrote loaded has finished loading.
    func didFinishLoading() {}

    /// Called after the web content process died; the page is gone.
    func contentProcessDidTerminate() {}

    // MARK: - WKNavigationDelegate

    func webView(
        _: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy(for: action))
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
           let index = expectedLoads.firstIndex(of: url) {
            expectedLoads.remove(at: index)
            return .allow
        }
        if action.targetFrame?.isMainFrame == true, isFragment(of: url) { return .allow }
        if action.navigationType == .linkActivated { open(url) }
        return .cancel
    }

    /// The current document with only a different `#fragment`.
    private func isFragment(of url: URL) -> Bool {
        guard url.fragment != nil, let current = self.url else { return false }
        return withoutFragment(url) == withoutFragment(current)
    }

    private func withoutFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        // A load that never reached the policy check was superseded.
        expectedLoads.removeAll()
        didFinishLoading()
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        expectedLoads.removeAll()
        contentProcessDidTerminate()
    }

    // MARK: - WKUIDelegate

    /// `window.open` and `target="_blank"`: never a new window, the link rule instead.
    func webView(
        _: WKWebView, createWebViewWith _: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url { open(url) }
        return nil
    }

    /// Local files go to the app; web and mail links to their own apps.
    private func open(_ url: URL) {
        if let path = PreviewURL.path(from: url) {
            onOpenFile?(path)
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The renderer page (`scwrote-app:///index.html`), loaded once, that draws
/// markdown, tables, diagrams and trees through `window.scwrote`.
@MainActor
final class PreviewDocumentWebView: PreviewWebView, WKScriptMessageHandler {
    /// The renderer's verdict on the shown content: an error, or a note.
    var onRendered: ((_ error: String?, _ note: String?) -> Void)?

    private let theme: [String: Any]
    private var isLoaded = false
    /// The request to render once the page has loaded.
    private var pending: [String: Any]?
    /// The newest request, cursor included, to render again if the page reloads.
    private var current: [String: Any]?
    /// Counts render calls; a reply from an older call is ignored.
    private var generation = 0
    /// The render call whose reply has not come back yet.
    private var inFlight: Int?
    /// A message that arrived while a render call was in flight. The page
    /// posts a render's message just before that render's reply, so the last
    /// one held when the reply comes is the render's own; earlier ones came
    /// from renders it superseded.
    private var held: (error: String?, note: String?)?
    /// Off while another body is shown: its messages describe nothing visible.
    private var isActive = false

    init(schemeHandler: PreviewSchemeHandler, theme: [String: Any], background: NSColor) {
        self.theme = theme
        let configuration = WKWebViewConfiguration()
        let messages = WeakMessageHandler()
        configuration.userContentController.add(messages, name: "scwrote")
        super.init(configuration: configuration, schemeHandler: schemeHandler, background: background)
        messages.target = self
        loadExpected(PreviewURL.appIndex)
    }

    /// Renders a `RenderRequest` (kind, text, baseURL, cursor); ends in one
    /// `onRendered`.
    func render(_ request: [String: Any]) {
        isActive = true
        current = request
        held = nil
        guard isLoaded else {
            pending = request
            return
        }
        generation += 1
        let call = generation
        inFlight = call
        callAsyncJavaScript("await scwrote.render(req)", arguments: ["req": request], in: nil, in: .page) { [weak self] result in
            self?.renderReturned(call, result)
        }
    }

    /// Another body is shown: drop what this one still reports.
    func deactivate() {
        isActive = false
        pending = nil
        current = nil
        inFlight = nil
        held = nil
    }

    func follow(_ cursor: CursorPosition) {
        let value = ["line": cursor.line, "column": cursor.column]
        current?["cursor"] = value
        guard isLoaded else {
            pending?["cursor"] = value
            return
        }
        callAsyncJavaScript("scwrote.follow(cursor)", arguments: ["cursor": value], in: nil, in: .page)
    }

    func command(_ name: String) {
        guard isLoaded else { return }
        callAsyncJavaScript("scwrote.command(name)", arguments: ["name": name], in: nil, in: .page)
    }

    private func renderReturned(_ call: Int, _ result: Result<Any, any Error>) {
        guard isActive, call == generation, inFlight == call else { return }
        inFlight = nil
        if let held {
            self.held = nil
            onRendered?(held.error, held.note)
        } else if case let .failure(error) = result {
            onRendered?(error.localizedDescription, nil)
        }
        // A success without a message was superseded by a re-render of the
        // page's own (a theme change), whose message comes later.
    }

    override func didFinishLoading() {
        guard !isLoaded else { return }
        isLoaded = true
        callAsyncJavaScript("scwrote.setTheme(theme)", arguments: ["theme": theme], in: nil, in: .page)
        if let pending {
            self.pending = nil
            render(pending)
        }
    }

    override func contentProcessDidTerminate() {
        // Load the page again and render what was shown; the dead call's
        // reply is dropped so the new render reports instead.
        isLoaded = false
        generation += 1
        inFlight = nil
        held = nil
        pending = isActive ? current : nil
        loadExpected(PreviewURL.appIndex)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
        pageFailed(error)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        pageFailed(error)
    }

    private func pageFailed(_ error: any Error) {
        guard !isLoaded, pending != nil else { return }
        pending = nil
        onRendered?("preview page failed to load: \(error.localizedDescription)", nil)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isActive, let body = message.body as? [String: Any] else { return }
        let result: (error: String?, note: String?)
        switch body["type"] as? String {
        case "rendered": result = (nil, body["note"] as? String)
        case "error": result = (body["message"] as? String ?? "render failed", nil)
        default: return
        }
        if inFlight != nil {
            held = result
        } else {
            // Not asked for: a re-render after a theme change, of what is shown.
            onRendered?(result.error, result.note)
        }
    }
}

/// User HTML, shown static: its scripts never run. scwrote's own evaluated
/// JavaScript still does, for scrolling.
@MainActor
final class PreviewHTMLWebView: PreviewWebView {
    /// Where to scroll, as a fraction of the scrollable height, once the
    /// document being loaded is in.
    private var pendingFraction: Double?
    private var isAwaitingLoad = false

    init(schemeHandler: PreviewSchemeHandler, background: NSColor) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        super.init(configuration: configuration, schemeHandler: schemeHandler, background: background)
    }

    func show(_ url: URL, scrolledTo fraction: Double) {
        pendingFraction = fraction
        isAwaitingLoad = true
        loadExpected(url)
    }

    func scroll(toFraction fraction: Double) {
        if isAwaitingLoad {
            pendingFraction = fraction
        } else {
            evaluateJavaScript("""
                window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(fraction))
                """)
        }
    }

    func command(_ command: PreviewCommand) {
        let line = "1.5 * parseFloat(getComputedStyle(document.documentElement).fontSize)"
        let script = switch command {
        case .lineDown: "window.scrollBy(0, \(line))"
        case .lineUp: "window.scrollBy(0, -\(line))"
        case .halfPageDown: "window.scrollBy(0, window.innerHeight / 2)"
        case .halfPageUp: "window.scrollBy(0, -window.innerHeight / 2)"
        case .top: "window.scrollTo(0, 0)"
        case .bottom: "window.scrollTo(0, document.documentElement.scrollHeight)"
        case .open, .close, .toggle, .leave: ""
        }
        if !script.isEmpty { evaluateJavaScript(script) }
    }

    override func didFinishLoading() {
        isAwaitingLoad = false
        if let pendingFraction {
            self.pendingFraction = nil
            scroll(toFraction: pendingFraction)
        }
    }
}

/// `WKUserContentController` keeps its handlers alive; this keeps the web
/// view that owns the controller from keeping itself alive.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
