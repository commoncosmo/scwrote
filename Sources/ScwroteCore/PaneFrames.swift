/// Horizontal spans of the panes for a given window width: browser | editor | preview.
/// Pure and stateless, so widening the window brings squeezed panes back.
///
/// When the window is too narrow, the unpinned browser gives way first, then
/// the preview; a pinned browser never does. The pane with the keyboard never
/// gives way, and while the browser has it neither does a shown preview (so
/// you can step through images): the editor yields its width instead, down to
/// nothing. Only below the two side panes' minimums together does one of
/// them go after all: the one without the keyboard.
public struct PaneFrames: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var x: Double
        public var width: Double
        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
    }

    public var browser: Span?
    /// In `.browserOnly` the browser covers the editor, so this is the browser's span.
    public var editor: Span
    public var preview: Span?
    /// Panes the layout wants but that were squeezed out for lack of room.
    public var gaveWay: Set<PaneLayout.Pane>

    public static let minBrowser = 160.0, minEditor = 320.0, minPreview = 240.0, divider = 1.0
    public static let defaultBrowserWidth = 280.0, defaultPreviewWidth = 420.0

    public static func compute(
        _ layout: PaneLayout, totalWidth: Double, browserWidth: Double, previewWidth: Double
    ) -> PaneFrames {
        var wantsBrowser = layout.mode != .editorOnly
        var wantsPreview = layout.isPreviewShown
        var gaveWay: Set<PaneLayout.Pane> = []

        if layout.mode == .browserOnly {
            // No editor: only the preview can give way.
            if wantsPreview && totalWidth < minBrowser + divider + minPreview {
                wantsPreview = false
                gaveWay.insert(.preview)
            }
            let previewSpan = wantsPreview ? clampedPreview(previewWidth, max: totalWidth - minBrowser - divider) : nil
            let browserWidth = previewSpan.map { totalWidth - $0 - divider } ?? totalWidth
            let browser = Span(x: 0, width: browserWidth)
            return PaneFrames(
                browser: browser, editor: browser,
                preview: previewSpan.map { Span(x: browserWidth + divider, width: $0) },
                gaveWay: gaveWay)
        }

        func needed(browser: Bool, preview: Bool) -> Double {
            minEditor + (browser ? minBrowser + divider : 0) + (preview ? minPreview + divider : 0)
        }
        let browserStays = layout.isPinned || layout.focus == .browser
        let previewStays = layout.focus == .preview || layout.focus == .browser
        if wantsBrowser && !browserStays && totalWidth < needed(browser: true, preview: wantsPreview) {
            wantsBrowser = false
            gaveWay.insert(.browser)
        }
        if wantsPreview && !previewStays && totalWidth < needed(browser: wantsBrowser, preview: true) {
            wantsPreview = false
            gaveWay.insert(.preview)
        }
        if wantsBrowser && wantsPreview && totalWidth < minBrowser + divider + minPreview + divider {
            // No room for both even with no editor.
            if layout.focus == .preview {
                wantsBrowser = false
                gaveWay.insert(.browser)
            } else {
                wantsPreview = false
                gaveWay.insert(.preview)
            }
        }

        var x = 0.0
        var browser: Span?
        if wantsBrowser {
            let room = totalWidth - needed(browser: false, preview: wantsPreview) - divider
            // A browser that stays keeps its minimum even when the editor then gets less than its own.
            let width = min(max(browserWidth, minBrowser), max(room, minBrowser))
            browser = Span(x: 0, width: width)
            x = width + divider
        }
        var previewWidthUsed = 0.0
        if wantsPreview {
            let room = totalWidth - x - minEditor - divider
            previewWidthUsed = clampedPreview(previewWidth, max: room)
        }
        let rightEdge = wantsPreview ? totalWidth - previewWidthUsed - divider : totalWidth
        let editor = Span(x: x, width: max(0, rightEdge - x))
        let preview = wantsPreview ? Span(x: rightEdge + divider, width: previewWidthUsed) : nil
        return PaneFrames(browser: browser, editor: editor, preview: preview, gaveWay: gaveWay)
    }

    private static func clampedPreview(_ width: Double, max room: Double) -> Double {
        min(Swift.max(width, minPreview), Swift.max(room, minPreview))
    }
}
