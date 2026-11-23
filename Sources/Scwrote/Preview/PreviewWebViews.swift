import AppKit
import ScwroteCore
import WebKit

/// A preview web view. It loads only what scwrote asks it to, sends clicked
/// links out instead of following them, and leaves the keyboard to the pane.
@MainActor
class PreviewWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    /// A clicked `scwrote-file` link, as a path.
    var onOpenFile: ((String) -> Void)?
    /// The newest load started by `loadExpected`, and how many times it was
    /// started without its policy check having come back yet. A load of a
    /// newer URL supersedes it. Anything else (links, forms, scripts,
    /// reloads, redirects) is cancelled.
    private var expectedLoad: (url: URL, count: Int)?

    init(configuration: WKWebViewConfiguration, schemeHandler: PreviewSchemeHandler, background: NSColor) {
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.appScheme)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.fileScheme)
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        underPageBackgroundColor = background
        // A force-click link preview loads the link outside the navigation
        // policy and the remote-content block.
        allowsLinkPreview = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keys go to the pane, which turns them into preview commands.
    override var acceptsFirstResponder: Bool { false }

    @discardableResult
    func loadExpected(_ url: URL) -> WKNavigation? {
        if expectedLoad?.url == url {
            expectedLoad?.count += 1
        } else {
            expectedLoad = (url, 1)
        }
        return load(URLRequest(url: url))
    }

    /// Called when a navigation scwrote let through has finished loading.
    func didFinishLoading(_: WKNavigation?) {}

    /// Called when a navigation failed, a superseded one included.
    func didFailLoading(_: WKNavigation?, error _: any Error) {}

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
           let expected = expectedLoad, expected.url == url {
            expectedLoad = expected.count > 1 ? (url, expected.count - 1) : nil
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

    func webView(_: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoading(navigation)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        didFailLoading(navigation, error: error)
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFailLoading(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
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

    private var theme: [String: Any]
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

    /// New colors: the page restyles, and redraws what it shows that its
    /// styles can't reach (diagrams). Before the page has loaded, it takes
    /// them when it does.
    func setTheme(_ theme: [String: Any], background: NSColor) {
        self.theme = theme
        underPageBackgroundColor = background
        guard isLoaded else { return }
        callAsyncJavaScript("scwrote.setTheme(theme)", arguments: ["theme": theme], in: nil, in: .page)
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

    override func didFinishLoading(_: WKNavigation?) {
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

    override func didFailLoading(_: WKNavigation?, error: any Error) {
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
/// JavaScript still does, for scrolling and for finding remote references.
/// Nothing from outside scwrote's own schemes loads into it (see
/// `RemoteContentRules`) unless the show allows remote content.
@MainActor
final class PreviewHTMLWebView: PreviewWebView {
    /// After a document loaded with remote content blocked: whether it
    /// references any, which is then what was kept from it.
    var onRemoteContent: ((Bool) -> Void)?
    /// After each show, if the blocking rules couldn't be compiled: no user
    /// HTML will load.
    var onError: ((String) -> Void)?

    /// Where to scroll, as a fraction of the scrollable height, once the
    /// document being loaded is in.
    private var pendingFraction: Double?
    /// The newest `show`'s load, until it finishes or fails. Only it ends the
    /// wait: an older load's end says nothing about the newer document.
    private var awaitedLoad: WKNavigation?
    private let contentController: WKUserContentController
    /// The blocking rules, once compiled. Until then nothing loads: the
    /// newest show waits in `queued`.
    private var rules: WKContentRuleList?
    private var queued: (url: URL, allowsRemoteContent: Bool)?
    /// Why the rules couldn't be compiled.
    private var rulesFailure: String?
    /// The rules are in the content controller: the newest load blocks
    /// remote content.
    private var isBlocking = false
    /// The newest show's URL.
    private var shownURL: URL?
    /// Counts shows; a scan of an older document is dropped.
    private var showCount = 0

    init(schemeHandler: PreviewSchemeHandler, background: NSColor) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        contentController = configuration.userContentController
        super.init(configuration: configuration, schemeHandler: schemeHandler, background: background)
        RemoteContentRules.whenCompiled { [weak self] in self?.rulesCompiled($0) }
    }

    /// Loads the file at `url`, with its remote content only if allowed.
    func show(_ url: URL, scrolledTo fraction: Double, allowingRemoteContent allows: Bool) {
        pendingFraction = fraction
        showCount += 1
        guard rules != nil else {
            if let rulesFailure {
                // After the caller's own report of this show, so this one stays.
                Task { [weak self] in self?.onError?(rulesFailure) }
            } else {
                queued = (url, allows)
            }
            return
        }
        load(url, allowingRemoteContent: allows)
    }

    /// Loads the shown document again, its remote content included, scrolled
    /// to where it is now.
    func reloadAllowingRemoteContent() {
        guard let url = shownURL else { return }
        if awaitedLoad != nil || queued != nil {
            show(url, scrolledTo: pendingFraction ?? 0, allowingRemoteContent: true)
            return
        }
        let count = showCount
        evaluateJavaScript(Self.scrolledFraction) { [weak self] result, _ in
            guard let self, count == showCount else { return }
            show(url, scrolledTo: result as? Double ?? 0, allowingRemoteContent: true)
        }
    }

    private func load(_ url: URL, allowingRemoteContent allows: Bool) {
        guard let rules else { return }
        if allows, isBlocking {
            contentController.remove(rules)
        } else if !allows, !isBlocking {
            contentController.add(rules)
        }
        isBlocking = !allows
        shownURL = url
        awaitedLoad = loadExpected(url)
    }

    private func rulesCompiled(_ result: Result<WKContentRuleList, any Error>) {
        switch result {
        case let .success(list):
            rules = list
            if let queued {
                self.queued = nil
                load(queued.url, allowingRemoteContent: queued.allowsRemoteContent)
            }
        case let .failure(error):
            rulesFailure = "cannot block remote content, so the page isn't shown: \(error.localizedDescription)"
            if queued != nil {
                queued = nil
                onError?(rulesFailure!)
            }
        }
    }

    func scroll(toFraction fraction: Double) {
        if awaitedLoad != nil || queued != nil {
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
        case .open, .close, .toggle, .leave, .loadRemoteContent: ""
        }
        if !script.isEmpty { evaluateJavaScript(script) }
    }

    override func didFinishLoading(_ navigation: WKNavigation?) {
        guard let navigation, navigation === awaitedLoad else { return }
        awaitedLoad = nil
        if let pendingFraction {
            self.pendingFraction = nil
            scroll(toFraction: pendingFraction)
        }
        guard isBlocking else { return }
        let count = showCount
        evaluateJavaScript(Self.remoteReferenceScan) { [weak self] result, _ in
            guard let self, count == showCount else { return }
            onRemoteContent?(result as? Bool ?? false)
        }
    }

    override func didFailLoading(_ navigation: WKNavigation?, error _: any Error) {
        guard let navigation, navigation === awaitedLoad else { return }
        awaitedLoad = nil
        pendingFraction = nil
    }

    override func contentProcessDidTerminate() {
        awaitedLoad = nil
        pendingFraction = nil
    }

    /// How far down the document is scrolled, from 0 to 1.
    private static let scrolledFraction = """
        (() => {
          const range = document.documentElement.scrollHeight - window.innerHeight;
          return range > 0 ? Math.min(Math.max(window.scrollY / range, 0), 1) : 0;
        })()
        """

    /// Whether the document references anything that would load from outside
    /// scwrote's own schemes: images (`srcset` too), media, embeds, frames,
    /// stylesheets, and `url(...)` / `@import` in its `<style>` elements,
    /// `style` attributes and the local stylesheets it links. Links don't
    /// count: they aren't loads.
    private static let remoteReferenceScan = #"""
        (() => {
          const local = new Set(["scwrote-file:", "scwrote-app:", "data:", "blob:", "about:"]);
          const isRemote = (value, base) => {
            if (!value || !value.trim()) return false;
            try { return !local.has(new URL(value.trim(), base || document.baseURI).protocol); }
            catch { return false; }
          };
          const cssReference = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)|@import\s+(?:"([^"]*)"|'([^']*)')/gi;
          const inCSS = (text, base) => {
            for (const m of (text || "").matchAll(cssReference)) {
              if (isRemote(m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5], base)) return true;
            }
            return false;
          };
          const attributes = [
            ["img[src], source[src], video[src], audio[src], embed[src], iframe[src], input[type=image][src]", "src"],
            ["video[poster]", "poster"],
            ["object[data]", "data"],
            ["link[rel~=stylesheet][href]", "href"],
          ];
          for (const [selector, name] of attributes) {
            for (const el of document.querySelectorAll(selector)) {
              if (isRemote(el.getAttribute(name))) return true;
            }
          }
          for (const el of document.querySelectorAll("img[srcset], source[srcset]")) {
            for (const candidate of el.getAttribute("srcset").split(",")) {
              if (isRemote(candidate.trim().split(/\s+/)[0])) return true;
            }
          }
          for (const el of document.querySelectorAll("style")) {
            if (inCSS(el.textContent)) return true;
          }
          for (const el of document.querySelectorAll("[style]")) {
            if (inCSS(el.getAttribute("style"))) return true;
          }
          for (const sheet of document.styleSheets) {
            if (!sheet.href) continue;
            try {
              for (const rule of sheet.cssRules) if (inCSS(rule.cssText, sheet.href)) return true;
            } catch {}
          }
          return false;
        })()
        """#
}

/// The content rules that keep remote content out of the HTML preview: every
/// load outside scwrote's own schemes and `data:`, `blob:` and `about:` is
/// blocked, except the top frame's navigations, which `PreviewWebView`'s
/// policy already governs (so clicked web links still open in the browser).
/// Compiled once and kept for the app's lifetime.
@MainActor
enum RemoteContentRules {
    private static let identifier = "scwrote-block-remote-content"
    /// Block everything, then let scwrote's own schemes through, one rule
    /// each: `url-filter` has no `|`.
    private static let encoded = """
        [
          {"trigger": {"url-filter": ".*", "resource-type": ["image", "style-sheet", "script", "font", "raw",
             "svg-document", "media", "ping", "fetch", "websocket", "other"]},
           "action": {"type": "block"}},
          {"trigger": {"url-filter": ".*", "resource-type": ["document"], "load-context": ["child-frame"]},
           "action": {"type": "block"}},
          {"trigger": {"url-filter": "^scwrote-file:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^scwrote-app:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
    private static var compiled: Result<WKContentRuleList, any Error>?
    /// Who asked while the rules were being compiled.
    private static var waiting: [(Result<WKContentRuleList, any Error>) -> Void]?

    /// Calls `done` with the compiled rules, at once if they are ready.
    static func whenCompiled(_ done: @escaping (Result<WKContentRuleList, any Error>) -> Void) {
        if let compiled {
            done(compiled)
            return
        }
        if waiting != nil {
            waiting?.append(done)
            return
        }
        waiting = [done]
        Task {
            let result: Result<WKContentRuleList, any Error>
            do {
                if let list = try await WKContentRuleListStore.default()
                    .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded)
                {
                    result = .success(list)
                } else {
                    result = .failure(CocoaError(.featureUnsupported))
                }
            } catch {
                result = .failure(error)
            }
            compiled = result
            let callers = waiting ?? []
            waiting = nil
            for caller in callers { caller(result) }
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
