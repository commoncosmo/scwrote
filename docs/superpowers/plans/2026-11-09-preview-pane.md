# Preview Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third pane to scwrote, right of the editor, that renders nvim's
current buffer (markdown, CSV, TSV, HTML, mermaid, SVG, JSON/YAML trees) or a
view-only file picked in the browser (images, PDF). It redraws on leaving insert
mode and follows the cursor.

**Architecture:** Pure rules live in `ScwroteCore` with Swift Testing tests:
pane layout and frames, file kinds, preview state, nvim event decoding, and a
second nvim RPC connection that receives autocommand notifications. The app
target hosts the pane: a native header, a `WKWebView` running a bundled
renderer page for the formats scwrote draws itself, a second script-disabled
`WKWebView` for user HTML, and `NSImageView`/`PDFView` for view-only files.
The renderer page is TypeScript under `web/`, tested with `bun test`, and
bundled by `bun run build` into the app's resources.

**Tech Stack:** Swift 6.2 / AppKit / WebKit / PDFKit, SwiftPM, Swift Testing;
nvim 0.12 msgpack-RPC + Lua autocommands; Bun (TypeScript, `bun test`,
`bun build`); markdown-it, mermaid, jsonc-parser, yaml (npm packages, via Bun).

**Spec:** `docs/superpowers/specs/2026-11-09-preview-pane-design.md`

## Global Constraints

- macOS 27, Swift tools 6.2, Swift language mode 6, one window per process.
- `ScwroteCore` stays free of AppKit/WebKit and unit tested; new pure logic goes there.
- Window keys are Cmd-only (`WindowShortcut`); nvim never receives Cmd keys.
- JavaScript tooling is **Bun only** (`bun`, `bunx`, `bun run`, `bun test`); never npm/npx/yarn/pnpm.
- Renderers ship inside the app; nothing loads from the network.
- The preview only observes nvim: no writes to files, buffers, options, or undo history.
- Nothing the preview does may slow nvim input; a slow render is the preview's problem.
- User HTML is static: its scripts never run. scwrote's own renderer scripts may.
- Broken input keeps the last good render and shows the error in the header.
- Colors and font come from the Ghostty config (via `Theme`), like the file browser.
- Installed copy must not depend on the repo: renderer assets ship in the resource bundle `install.sh` already copies (`.build/release/*.bundle`).
- README documents keys and layout and must be updated.

## Review Focus

1. **Non-ASCII text and cursor columns.** A CSV line `é,b` with the cursor on `b` must highlight column 2, not a byte offset. Pinned in Task 4 (`cursorColumnsCountCharactersNotBytes`) and Task 6 (`fieldAtCountsCharacters`).
2. **Paths with spaces, `#`, `%`, `?`, quotes** in markdown images, links, and HTML assets must resolve through the `scwrote-file` scheme. Pinned in Task 5 (`PreviewURLTests`).
3. **Very large buffers** (10 MB minified JSON, 200k-row CSV) must not stall nvim or the window: the Lua side sends no text above `PreviewLimits.maxBufferBytes` and the header says so; CSV caps rows. Pinned in Task 4 (`hugeBuffersAreSentWithoutText`), Task 5 (`tooLargeBufferShowsAMessage`), Task 6 (`capsRowsAndReportsTotal`).
4. **Empty files** (new `untitled.json`, empty CSV, empty markdown) show an empty preview, not an error. Pinned in Task 6 (`emptyTextHasNoRows`) and Task 8 (`emptyTextIsNotAnError`).
5. **Raw HTML inside markdown and SVG** (`<img onerror=…>`, `<script>`) must not run. The page's CSP blocks inline scripts and SVG is shown through `<img>`. The CSP shape is pinned in Task 9 (`build.test.ts`), and the behavior by the in-app check `markdownPageNeverRunsInlineScript` in Task 11, Step 3.

---

## File Structure

**ScwroteCore (pure, tested)**
- `Sources/ScwroteCore/PaneLayout.swift`: modify. Adds the preview pane, focus `.preview`, and pane-to-pane moves.
- `Sources/ScwroteCore/PaneFrames.swift`: create. Turns a `PaneLayout` plus window width into pane spans, deciding which panes give way.
- `Sources/ScwroteCore/WindowShortcut.swift`: modify. Adds Cmd+2 and renames the bracket keys to left/right moves.
- `Sources/ScwroteCore/PreviewKind.swift`: create. Works out a file's preview kind from its extension and nvim filetype.
- `Sources/ScwroteCore/PreviewEvent.swift`: create. `BufferSnapshot`, `CursorPosition`, `PreviewEvent` decoded from nvim notifications.
- `Sources/ScwroteCore/PreviewAutocommands.swift`: create. The Lua source that installs the autocommands, plus `PreviewLimits`.
- `Sources/ScwroteCore/NvimClient.swift`: modify. Queues notifications instead of dropping them; adds `nextNotification()` and `channelID()`.
- `Sources/ScwroteCore/NvimEventListener.swift`: create. A dedicated connection: installs the autocommands, then delivers `PreviewEvent`s on a thread.
- `Sources/ScwroteCore/PreviewState.swift`: create. Which file is shown, the header model, and the effect of each event.
- `Sources/ScwroteCore/PreviewURL.swift`: create. Converts between file paths and `scwrote-file:` URLs.
- `Sources/ScwroteCore/PreviewKeys.swift`: create. Turns `BrowserKey` into `PreviewCommand` (handles `gg`).

**Renderer page (`web/`, Bun)**
- `web/package.json`, `web/bun.lock`, `web/tsconfig.json`
- `web/src/csv.ts`: delimited parsing with source positions.
- `web/src/follow.ts`: maps a cursor line to a block.
- `web/src/markdown.ts`: markdown-it setup with source-line attributes and mermaid fences.
- `web/src/tree.ts`: JSON/YAML trees with line ranges, plus open-state rules.
- `web/src/page.ts`: the page entry point. DOM rendering per kind, theme variables, keys, the Swift bridge.
- `web/index.html`, `web/page.css`
- `web/build.ts`: bundles into `Sources/Scwrote/Resources/Preview/`.
- `web/test/*.test.ts`

**App (`Sources/Scwrote`)**
- `Theme.swift`: modify. Adds a `warning` color (palette 3) and CSS hex output.
- `FileBrowserView.swift`: modify. Makes `browserKey(for:)` reusable by the preview.
- `Preview/PreviewSchemeHandler.swift`: create. Serves `scwrote-app:` (bundle) and `scwrote-file:` (disk, with a buffer overlay).
- `Preview/PreviewHeaderView.swift`: create.
- `Preview/PreviewPaneView.swift`: create. Header, edge stripe, and body views; keys and links.
- `EditorLayoutView.swift`: modify. Lays out three panes from `PaneFrames`, with two draggable dividers.
- `EditorWindowController.swift` and `EditorWindowController+Preview.swift` (create): wiring.
- `MainMenu.swift`, `DebugHooks.swift`: modify.
- `Package.swift`, `install.sh`, `.gitignore`, `README.md`: modify.

---

### Task 1: PreviewKind

**Files:**
- Create: `Sources/ScwroteCore/PreviewKind.swift`
- Test: `Tests/ScwroteCoreTests/PreviewKindTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PreviewKind: String, Equatable, Sendable {
      case markdown, csv, tsv, html, mermaid, svg, json, yaml, image, pdf, unsupported
      public init(path: String, filetype: String? = nil)
      public var displayName: String   // "Markdown","CSV","TSV","HTML","Mermaid","SVG","JSON","YAML","Image","PDF","no preview"
      public var isViewOnly: Bool      // image, pdf
      public var rendersInPage: Bool   // markdown, csv, tsv, mermaid, svg, json, yaml
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run, expect failure:** `swift test --filter PreviewKindTests` → compile error, `PreviewKind` not found.
- [ ] **Step 3: Implement `PreviewKind` in `Sources/ScwroteCore/PreviewKind.swift`.** Match extensions case-insensitively. Image extensions: png jpg jpeg gif webp heic heif tiff tif bmp ico. Filetypes recognized: markdown, csv, tsv, html, mermaid, svg, json, jsonc, yaml.
- [ ] **Step 4: Run, expect pass:** `swift test --filter PreviewKindTests`
- [ ] **Step 5: Commit:** `git add Sources/ScwroteCore/PreviewKind.swift Tests/ScwroteCoreTests/PreviewKindTests.swift && git commit -m "Add PreviewKind: which preview a file gets"`

---

### Task 2: Three-pane layout rules and shortcuts

**Files:**
- Modify: `Sources/ScwroteCore/PaneLayout.swift`, `Sources/ScwroteCore/WindowShortcut.swift`
- Test: `Tests/ScwroteCoreTests/PaneLayoutTests.swift`, `Tests/ScwroteCoreTests/WindowShortcutTests.swift`

**Interfaces:**
- Produces (additions to `PaneLayout`; existing API and behavior unchanged except as noted):
  ```swift
  public enum Pane { case browser, editor, preview }          // + .preview
  public private(set) var isPreviewShown: Bool                 // starts false
  public var editorHasFile: Bool { get }                       // make the existing private var readable
  public mutating func togglePreview()        // Cmd+2
  public mutating func moveLeft()             // Cmd+[  (replaces focusBrowser as the key's action; keep focusBrowser)
  public mutating func moveRight()            // Cmd+]  (replaces leaveBrowser as the key's action; keep leaveBrowser)
  public mutating func leavePreview()         // Esc in the preview
  public mutating func openedViewOnlyFile()   // browser chose an image/PDF
  public mutating func paneGaveWay(_ pane: Pane)  // PaneFrames squeezed out the focused pane
  // clicked(.preview) is now valid: focus = .preview
  ```
- `WindowShortcut`: cases become `toggleBrowser, toggleBrowserPin, togglePreview, moveLeft, moveRight`. `togglePreview` is keyCode 19 (the 2 key) + Cmd. `goToBrowser` is renamed to `moveLeft`, and `goToEditor` to `moveRight`.

Rules (from the spec):
- `togglePreview`: hidden → shown, focus `.preview`. Shown and not focused → focus `.preview`. Shown and focused → hidden, focus `.editor` if `editorHasFile`, else `.browser`.
- `moveLeft`: `.preview` → `.editor` if `editorHasFile`, else `.browser`. `.editor` → same as `focusBrowser()`. `.browser` → no change.
- `moveRight`: `.browser` → same as `leaveBrowser()` (a no-op without a file). `.editor` → `.preview` if shown. `.preview` → no change.
- `leavePreview`: same target as `moveLeft` from `.preview`.
- `openedViewOnlyFile`: `isPreviewShown = true`. Focus and `mode` don't change: the browser stays open and focused, even unpinned, and even in `.browserOnly`.
- `paneGaveWay(p)`: if `focus == p` and `editorHasFile`, focus becomes `.editor`.

- [ ] **Step 1: Write the failing tests** (add a `PaneLayoutPreviewTests` suite; update the bracket test in `WindowShortcutTests`)

```swift
struct PaneLayoutPreviewTests {
    @Test func cmd2ShowsGoesToThenHidesThePreview() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        #expect(layout.isPreviewShown && layout.focus == .preview)
        layout.clicked(.editor)
        layout.togglePreview()
        #expect(layout.isPreviewShown && layout.focus == .preview)
        layout.togglePreview()
        #expect(!layout.isPreviewShown && layout.focus == .editor)
    }

    @Test func bracketsMoveOnePaneAtATime() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()               // in the preview
        layout.moveLeft()
        #expect(layout.focus == .editor)
        layout.moveLeft()
        #expect(layout.focus == .browser && layout.mode == .split)
        layout.moveLeft()
        #expect(layout.focus == .browser)
        layout.moveRight()                    // unpinned browser hides on leaving
        #expect(layout.focus == .editor && layout.mode == .editorOnly)
        layout.moveRight()
        #expect(layout.focus == .preview)
        layout.moveRight()
        #expect(layout.focus == .preview)
    }

    @Test func moveRightFromTheEditorDoesNothingWithoutAPreview() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.moveRight()
        #expect(layout.focus == .editor && !layout.isPreviewShown)
    }

    @Test func leavingThePreviewKeepsItShown() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        layout.leavePreview()
        #expect(layout.focus == .editor && layout.isPreviewShown)
    }

    @Test func choosingAnImageShowsThePreviewAndStaysInTheBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()                // unpinned, focused
        layout.openedViewOnlyFile()
        #expect(layout.isPreviewShown && layout.focus == .browser && layout.mode == .split)
    }

    @Test func beforeAnyFileThePreviewSitsBesideTheFullBrowser() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.openedViewOnlyFile()
        #expect(layout.mode == .browserOnly && layout.isPreviewShown && layout.focus == .browser)
        layout.moveRight()                    // Cmd+] still does nothing until a file is open
        #expect(layout.focus == .browser)
        layout.leaveBrowser()
        #expect(layout.focus == .browser)
    }

    @Test func aPaneThatGivesWayHandsFocusToTheEditor() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        layout.paneGaveWay(.preview)
        #expect(layout.focus == .editor && layout.isPreviewShown)
    }

    @Test func openingAFileKeepsThePreviewShown() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.togglePreview()
        layout.openedFile()
        #expect(layout.isPreviewShown && layout.focus == .editor)
    }
}
```

In `WindowShortcutTests`, replace `cmdBracketsGoToEachPane` with checks that `[` + Cmd gives `.moveLeft` and `]` + Cmd gives `.moveRight`. Add `cmd2TogglesThePreview`, checking that keyCode 19 + Cmd gives `.togglePreview` and keyCode 19 + Cmd+Shift gives `nil`.

- [ ] **Step 2: Run, expect failure:** `swift test --filter "PaneLayout|WindowShortcut"` → compile errors (`togglePreview`, `.moveLeft` missing).
- [ ] **Step 3: Implement the rules above in `PaneLayout.swift` and the new cases in `WindowShortcut.swift`.** Update `EditorWindowController.perform(_:)` to call `change { $0.moveLeft() }`, `change { $0.moveRight() }` and `change { $0.togglePreview() }` (the last is a no-op visually until Task 11), so the app still builds.
- [ ] **Step 4: Run, expect pass:** `swift test` (the whole suite, since existing PaneLayout tests must still pass) and `swift build`.
- [ ] **Step 5: Commit:** `git commit -am "PaneLayout: add the preview pane and left/right pane moves"`

---

### Task 3: PaneFrames (who fits)

**Files:**
- Create: `Sources/ScwroteCore/PaneFrames.swift`
- Test: `Tests/ScwroteCoreTests/PaneFramesTests.swift`

**Interfaces:**
- Consumes: `PaneLayout` (`mode`, `isPinned`, `isPreviewShown`) from Task 2.
- Produces:
  ```swift
  public struct PaneFrames: Equatable, Sendable {
      public struct Span: Equatable, Sendable { public var x: Double; public var width: Double }
      public var browser: Span?
      public var editor: Span         // in .browserOnly the browser covers it (same span), as today
      public var preview: Span?
      public var gaveWay: Set<PaneLayout.Pane>   // wanted by the layout, squeezed out for lack of room
      public static let minBrowser = 160.0, minEditor = 320.0, minPreview = 240.0, divider = 1.0
      public static let defaultBrowserWidth = 280.0, defaultPreviewWidth = 420.0
      public static func compute(_ layout: PaneLayout, totalWidth: Double,
                                 browserWidth: Double, previewWidth: Double) -> PaneFrames
  }
  ```
  `PaneLayout.Pane` must be `Hashable` (add the conformance).

Rules: The browser is wanted when `mode != .editorOnly`, the preview when `isPreviewShown`. If the minimums plus dividers don't fit, the unpinned browser gives way first, then the preview. A pinned browser never gives way. In `.browserOnly` there is no editor, so only the preview can give way: it needs `minBrowser + divider + minPreview`. Widths are clamped: browser to `[minBrowser, room]`, preview to `[minPreview, room]`, and the editor gets the rest. Order is browser, divider, editor, divider, preview. The function keeps no state, so widening the window brings squeezed panes back.

- [ ] **Step 1: Write the failing tests**

```swift
struct PaneFramesTests {
    private func layout(browser: Bool = false, pinned: Bool = false, preview: Bool = false) -> PaneLayout {
        var layout = PaneLayout(startsInBrowser: false)
        if pinned { layout.togglePin() } else if browser { layout.toggleBrowser() }
        if preview { layout.togglePreview() }
        return layout
    }
    private func span(_ x: Double, _ width: Double) -> PaneFrames.Span { .init(x: x, width: width) }

    @Test func editorAloneFillsTheWindow() {
        let frames = PaneFrames.compute(layout(), totalWidth: 1000, browserWidth: 280, previewWidth: 420)
        #expect(frames.editor == span(0, 1000) && frames.browser == nil && frames.preview == nil)
    }

    @Test func allThreeSideBySide() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 1200, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == span(0, 280))
        #expect(frames.editor == span(281, 498))
        #expect(frames.preview == span(780, 420))
        #expect(frames.gaveWay.isEmpty)
    }

    @Test func unpinnedBrowserGivesWayFirst() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 700, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == nil && frames.gaveWay == [.browser])
        #expect(frames.editor == span(0, 320))
        #expect(frames.preview == span(321, 379))
    }

    @Test func thenThePreview() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 500, browserWidth: 280, previewWidth: 420)
        #expect(frames.gaveWay == [.browser, .preview] && frames.editor == span(0, 500))
    }

    @Test func aPinnedBrowserNeverGivesWay() {
        let frames = PaneFrames.compute(layout(pinned: true, preview: true), totalWidth: 700, browserWidth: 280, previewWidth: 420)
        #expect(frames.gaveWay == [.preview])
        #expect(frames.browser == span(0, 280) && frames.editor == span(281, 419))
    }

    @Test func widerAgainBringsThemBack() {
        let wanted = layout(browser: true, preview: true)
        _ = PaneFrames.compute(wanted, totalWidth: 500, browserWidth: 280, previewWidth: 420)
        #expect(PaneFrames.compute(wanted, totalWidth: 1200, browserWidth: 280, previewWidth: 420).gaveWay.isEmpty)
    }

    @Test func previewBesideTheFullWindowBrowser() {
        var start = PaneLayout(startsInBrowser: true)
        start.openedViewOnlyFile()
        let frames = PaneFrames.compute(start, totalWidth: 1000, browserWidth: 280, previewWidth: 420)
        #expect(frames.browser == span(0, 579) && frames.editor == span(0, 579) && frames.preview == span(580, 420))
    }

    @Test func draggedWidthsAreClamped() {
        let frames = PaneFrames.compute(layout(browser: true, preview: true), totalWidth: 1200, browserWidth: 20, previewWidth: 5000)
        #expect(frames.browser?.width == 160)
        #expect(frames.editor.width == 320)
        #expect(frames.preview?.width == 718)
    }
}
```

- [ ] **Step 2: Run, expect failure:** `swift test --filter PaneFramesTests` → `PaneFrames` not found.
- [ ] **Step 3: Implement `PaneFrames.compute` per the rules.** Clamp the browser first, then the preview against what's left after `minEditor`. That ordering is what `draggedWidthsAreClamped` pins.
- [ ] **Step 4: Run, expect pass:** `swift test --filter PaneFramesTests`
- [ ] **Step 5: Commit:** `git commit -am "Add PaneFrames: pane spans and which panes give way"` (after `git add` of the new files)

---

### Task 4: nvim events (autocommands, notifications, listener)

**Files:**
- Modify: `Sources/ScwroteCore/NvimClient.swift`
- Create: `Sources/ScwroteCore/PreviewEvent.swift`, `Sources/ScwroteCore/PreviewAutocommands.swift`, `Sources/ScwroteCore/NvimEventListener.swift`
- Create: `Tests/ScwroteCoreTests/HeadlessNvim.swift` (move the private `HeadlessNvim` and `realpath` helpers out of `NvimClientTests.swift`, make them internal)
- Test: `Tests/ScwroteCoreTests/PreviewEventTests.swift`, `Tests/ScwroteCoreTests/NvimEventListenerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct CursorPosition: Equatable, Sendable { public var line: Int; public var column: Int }  // line 1-based; column 0-based, in characters
  public struct BufferSnapshot: Equatable, Sendable {
      public var path: String; public var filetype: String
      public var text: String?          // nil when larger than PreviewLimits.maxBufferBytes
      public var isModified: Bool; public var cursor: CursorPosition
  }
  public enum PreviewEvent: Equatable, Sendable {
      case buffer(BufferSnapshot)
      case modified(path: String, isModified: Bool)
      case cursor(path: String, CursorPosition)
      public init?(method: String, params: [MessagePackValue])   // method must be "scwrote_preview"
  }
  public enum PreviewLimits { public static let maxBufferBytes = 10_000_000 }
  public enum PreviewAutocommands { public static let lua: String }   // run via nvim_exec_lua with args [channelID]
  extension NvimClient {
      public func channelID() throws -> Int64                          // nvim_get_api_info()[0]
      public func nextNotification() throws -> (method: String, params: [MessagePackValue])
  }
  public final class NvimEventListener: @unchecked Sendable {
      public init(socketPath: String, connectTimeout: TimeInterval = 2)
      /// Connects, installs the autocommands, then calls onEvent on a background thread for each event; onEnd once when nvim goes away or stop() is called.
      public func start(onEvent: @escaping @Sendable (PreviewEvent) -> Void, onEnd: @escaping @Sendable () -> Void)
      public func stop()
  }
  ```

**Notification contract** (Lua → Swift). Method `"scwrote_preview"`, one param, a map:
- `{type="buffer", path, filetype, modified, text, line, column}`. `text` is omitted when the buffer is over `maxBufferBytes` (use `nvim_buf_get_offset(buf, line_count)`). Sent once at install time for the current window, then on `BufEnter`, `InsertLeave`, `TextChanged`, `BufWritePost`.
- `{type="modified", path, modified}` on `BufModifiedSet` (uses `args.buf`).
- `{type="cursor", path, line, column}` on `CursorMoved`, `CursorMovedI`. `column` is `vim.fn.charcol('.') - 1`.
- Only real files count: `buftype == ""`, a non-empty name, and for window-based events the current window is not floating (`nvim_win_get_config(0).relative == ""`). Everything else sends nothing.
- No event on `TextChangedI`: that's the "redraw on Esc" rule.
- Augroup `ScwrotePreview` with `clear = true`, so reinstalling is idempotent. The Lua receives the channel ID as `...`.

**NvimClient changes:** `response(to:)` must queue notification messages (`[2, method, params]`) instead of dropping them, because the first `buffer` event arrives during the install request. `nextNotification()` returns queued notifications first, then reads. A read timeout (`SO_RCVTIMEO`, errno `EAGAIN`/`EWOULDBLOCK`) means keep waiting. EOF or other errors throw `.connectionLost`.

- [ ] **Step 1: Write the failing decode tests** (`PreviewEventTests`): a map with `type="buffer"` and every field decodes to `.buffer`. Missing `text` gives `text == nil`. `type="modified"` and `type="cursor"` decode. A method other than `scwrote_preview`, an unknown `type`, or a missing `path` gives `nil`. Lua integers arrive as `.int` and booleans as `.bool`.
- [ ] **Step 2: Write the failing listener tests** (`NvimEventListenerTests`, `@Suite(.enabled(if: nvimPath != nil))`). A helper `EventLog` collects events behind a lock, and `waitFor(_ predicate:, timeout: 2)` polls it. Each test starts `HeadlessNvim`, uses an `NvimClient` to `edit` a temp file, then starts the listener and drives nvim with `client.request("nvim_input", [.string(keys)])`:
  - `startingOnARealFileSendsItsBuffer`: the first `.buffer` has `path == realpath(file)`, `text == "# hi"`, `isModified == false`.
  - `typingSendsModifiedAtOnceButTextOnlyOnEsc`: input `ohello`, then wait for `.modified(_, true)`, and assert no `.buffer` event contains `"hello"` yet. Input `<Esc>`, then wait for a `.buffer` whose text is `"# hi\nhello"`.
  - `normalModeEditsSendText`: `dd` gives a `.buffer` with `text == ""`.
  - `savingClearsModified`: `ox<Esc>:w<CR>` gives a last `.buffer` with `isModified == false`.
  - `cursorMovesAreSent`: on a two-line file, `j` gives `.cursor(_, CursorPosition(line: 2, column: 0))`.
  - `cursorColumnsCountCharactersNotBytes`: on a file `é,b`, `$` gives `column == 2`.
  - `helpAndFloatingWindowsAreIgnored`: `:help<CR>` and a floating window opened with `nvim_open_win` on a scratch buffer produce no `.buffer` or `.cursor` events within 0.5 s whose path isn't the test file.
  - `hugeBuffersAreSentWithoutText`: edit a file just over `maxBufferBytes`, and its `.buffer` has `text == nil`.
  - `nvimExitingEndsTheListener`: `:qa!<CR>` calls `onEnd` within 2 s.
- [ ] **Step 3: Run, expect failure:** `swift test --filter "PreviewEvent|NvimEventListener"` → compile errors.
- [ ] **Step 4: Implement** `PreviewEvent.init?(method:params:)`, the `NvimClient` changes, `PreviewAutocommands.lua` per the contract, and `NvimEventListener`. The listener uses its own `NvimClient` on a dedicated `Thread`: `channelID()`, then `nvim_exec_lua(lua, [chan])`, then loop on `nextNotification()`. `stop()` closes the socket, which ends the loop. Expose an internal `NvimClient.close()` for that.
- [ ] **Step 5: Run, expect pass:** `swift test` (existing `NvimClientTests` must still pass after the helper move).
- [ ] **Step 6: Commit:** `git add -A Sources/ScwroteCore Tests/ScwroteCoreTests && git commit -m "Listen to nvim for preview events over a second RPC connection"`

---

### Task 5: PreviewState, PreviewURL, PreviewKeys

**Files:**
- Create: `Sources/ScwroteCore/PreviewState.swift`, `Sources/ScwroteCore/PreviewURL.swift`, `Sources/ScwroteCore/PreviewKeys.swift`
- Test: `Tests/ScwroteCoreTests/PreviewStateTests.swift`, `Tests/ScwroteCoreTests/PreviewURLTests.swift`, `Tests/ScwroteCoreTests/PreviewKeysTests.swift`

**Interfaces:**
- Consumes: `PreviewKind` (Task 1), `PreviewEvent`, `BufferSnapshot`, `CursorPosition` (Task 4), `BrowserKey` (existing).
- Produces:
  ```swift
  public struct PreviewHeader: Equatable, Sendable {
      public var label: String        // "README.md · Markdown", "Main.swift · no preview", "No file"
      public var isUnsaved: Bool
      public var message: String?     // error or note text, without the ⚠
      public var isError: Bool
  }
  public enum PreviewEffect: Equatable, Sendable { case render, headerOnly, follow(CursorPosition), nothing }
  public struct PreviewState: Equatable, Sendable {
      public enum Target: Equatable, Sendable { case none, buffer(BufferSnapshot), viewOnly(path: String) }
      public init()
      public private(set) var target: Target
      public var kind: PreviewKind { get }     // .unsupported for .none
      public var header: PreviewHeader { get }
      public mutating func apply(_ event: PreviewEvent) -> PreviewEffect
      public mutating func pickViewOnly(_ path: String) -> PreviewEffect      // always .render
      public mutating func returnToEditor() -> PreviewEffect                  // .render if the target changed, else .nothing
      public mutating func rendered(error: String?, note: String?)           // from the renderer
  }
  public enum PreviewURL {
      public static func file(_ path: String) -> URL            // scwrote-file:///abs/path, percent-encoded
      public static func folder(of path: String) -> URL         // scwrote-file:///abs/dir/ (trailing slash), for <base href>
      public static func path(from url: URL) -> String?         // nil unless scheme is scwrote-file
      public static let appIndex: URL                           // scwrote-app:///index.html
  }
  public enum PreviewCommand: Equatable, Sendable { case lineDown, lineUp, halfPageDown, halfPageUp, top, bottom, open, close, toggle, leave }
  public struct PreviewKeyReader: Sendable {
      public init()
      public mutating func read(_ key: BrowserKey) -> PreviewCommand?   // j/↓ k/↑ C-d C-u gg G l/→ h/← Enter/o Esc
  }
  ```

State rules:
- `.buffer(s)`: if the target is `.none` or `.buffer`, the target becomes `s` → `.render`. If the target is `.viewOnly`: a different path from the last buffer → the target becomes `s`, `.render`; the same path → remember `s` and return `.nothing`.
- `.modified(p, m)`: for the shown buffer, update `isModified` → `.headerOnly`. Otherwise remember it if it's the last buffer → `.nothing`.
- `.cursor(p, c)`: for the shown buffer → `.follow(c)`. Otherwise `.nothing`.
- A new target clears `message`. `rendered` sets `message` and `isError`.
- `header.isUnsaved` is only ever true for a `.buffer` target.
- A buffer with `text == nil` gives the message `"too large to preview"`, `isError == false`.

- [ ] **Step 1: Write the failing tests**

```swift
struct PreviewStateTests {
    private func snap(_ path: String, _ text: String? = "x", modified: Bool = false) -> BufferSnapshot {
        BufferSnapshot(path: path, filetype: "", text: text, isModified: modified, cursor: .init(line: 1, column: 0))
    }

    @Test func startsWithNoFile() {
        #expect(PreviewState().header == PreviewHeader(label: "No file", isUnsaved: false, message: nil, isError: false))
    }

    @Test func showsTheBufferAndItsUnsavedState() {
        var state = PreviewState()
        #expect(state.apply(.buffer(snap("/n/README.md"))) == .render)
        #expect(state.header.label == "README.md · Markdown" && !state.header.isUnsaved)
        #expect(state.apply(.modified(path: "/n/README.md", isModified: true)) == .headerOnly)
        #expect(state.header.isUnsaved)
        #expect(state.apply(.modified(path: "/n/other.md", isModified: true)) == .nothing)
    }

    @Test func followsTheCursorOfTheShownBufferOnly() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.csv")))
        #expect(state.apply(.cursor(path: "/n/a.csv", .init(line: 3, column: 2))) == .follow(.init(line: 3, column: 2)))
        #expect(state.apply(.cursor(path: "/n/b.csv", .init(line: 1, column: 0))) == .nothing)
    }

    @Test func aPickedImageStaysUntilYouReturnOrSwitchFiles() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.md", modified: true)))
        #expect(state.pickViewOnly("/n/photo.jpg") == .render)
        #expect(state.header.label == "photo.jpg · Image" && !state.header.isUnsaved)
        #expect(state.apply(.buffer(snap("/n/a.md", "new"))) == .nothing)
        #expect(state.returnToEditor() == .render)
        #expect(state.target == .buffer(snap("/n/a.md", "new")))
        _ = state.pickViewOnly("/n/photo.jpg")
        #expect(state.apply(.buffer(snap("/n/b.md"))) == .render)
    }

    @Test func returningWhenAlreadyOnTheBufferChangesNothing() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.md")))
        #expect(state.returnToEditor() == .nothing)
    }

    @Test func errorsAndNotesShowUntilTheNextFile() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/a.json")))
        state.rendered(error: "line 14: unexpected \"}\"", note: nil)
        #expect(state.header.message == "line 14: unexpected \"}\"" && state.header.isError)
        state.rendered(error: nil, note: "showing 5,000 of 182,340 rows")
        #expect(state.header.message == "showing 5,000 of 182,340 rows" && !state.header.isError)
        _ = state.apply(.buffer(snap("/n/b.json")))
        #expect(state.header.message == nil)
    }

    @Test func unsupportedFilesSayNoPreview() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/Main.swift")))
        #expect(state.header.label == "Main.swift · no preview")
    }

    @Test func tooLargeBufferShowsAMessage() {
        var state = PreviewState()
        _ = state.apply(.buffer(snap("/n/big.json", nil)))
        #expect(state.header.message == "too large to preview" && !state.header.isError)
    }
}

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

struct PreviewKeysTests {
    @Test func vimKeysBecomeCommands() {
        var reader = PreviewKeyReader()
        #expect(reader.read(.character("j")) == .lineDown)
        #expect(reader.read(.up) == .lineUp)
        #expect(reader.read(.halfPageDown) == .halfPageDown)
        #expect(reader.read(.character("G")) == .bottom)
        #expect(reader.read(.character("l")) == .open)
        #expect(reader.read(.left) == .close)
        #expect(reader.read(.enter) == .toggle)
        #expect(reader.read(.escape) == .leave)
    }

    @Test func ggNeedsBothKeys() {
        var reader = PreviewKeyReader()
        #expect(reader.read(.character("g")) == nil)
        #expect(reader.read(.character("g")) == .top)
        #expect(reader.read(.character("g")) == nil)
        #expect(reader.read(.character("x")) == nil)
        #expect(reader.read(.character("j")) == .lineDown)
    }
}
```

- [ ] **Step 2: Run, expect failure:** `swift test --filter "PreviewState|PreviewURL|PreviewKeys"`
- [ ] **Step 3: Implement the three files per the interfaces and rules.** `PreviewURL.file` builds the URL with `URLComponents` (scheme `scwrote-file`, empty host, `path` set), so `#`, `%` and `?` are encoded.
- [ ] **Step 4: Run, expect pass:** `swift test`
- [ ] **Step 5: Commit:** `git commit -m "Add PreviewState, PreviewURL and preview keys"` (after `git add`)

---

### Task 6: Renderer project scaffold, CSV/TSV and cursor mapping

**Files:**
- Create: `web/package.json`, `web/tsconfig.json`, `web/src/csv.ts`, `web/src/follow.ts`, `web/test/csv.test.ts`, `web/test/follow.test.ts`
- Modify: `.gitignore` (add `web/node_modules/` and `Sources/Scwrote/Resources/Preview/`)

**Interfaces:**
- Produces:
  ```ts
  // csv.ts
  export interface Field { text: string; line: number; column: number }   // start position: 1-based line, 0-based char column
  export interface Table { rows: Field[][]; totalRows: number; error?: string }  // error like "line 7: unclosed quote"
  export function parseDelimited(text: string, delimiter: "," | "\t", maxRows: number): Table
  export function fieldAt(table: Table, line: number, column: number): { row: number; column: number } | null
  export const MAX_ROWS = 5000
  // follow.ts
  export interface Block { start: number; end: number }   // 1-based inclusive source lines
  export function blockForLine(blocks: Block[], line: number): number   // index of innermost block containing line, else last block starting before it, else 0; -1 if no blocks
  ```
- `package.json` scripts: `"test": "bun test"`, `"build": "bun run build.ts"`. Dependencies are added with `bun add markdown-it mermaid jsonc-parser yaml` and `bun add -d @types/markdown-it @types/bun`. Commit `bun.lock`.

CSV rules follow RFC 4180: quotes, doubled quotes, delimiters and newlines inside quotes. `\r\n` and a trailing newline don't add an empty row. Ragged rows are kept as they are. Stop collecting after `maxRows`, but keep counting into `totalRows`.

- [ ] **Step 1: Write the failing tests** (`bun test` style, `import { expect, test } from "bun:test"`)

```ts
test("splits rows and fields with positions", () => {
  const t = parseDelimited("a,b\nc,d\n", ",", MAX_ROWS);
  expect(t.rows.map(r => r.map(f => f.text))).toEqual([["a", "b"], ["c", "d"]]);
  expect(t.rows[1][1]).toEqual({ text: "d", line: 2, column: 2 });
});
test("quoted fields hold commas, quotes and newlines", () => {
  const t = parseDelimited('x,"a,""b""\nc"\ny,z', ",", MAX_ROWS);
  expect(t.rows[0][1].text).toBe('a,"b"\nc');
  expect(t.rows[1][0]).toEqual({ text: "y", line: 3, column: 0 });
});
test("tabs for TSV", () => {
  expect(parseDelimited("a\tb", "\t", MAX_ROWS).rows[0].length).toBe(2);
});
test("emptyTextHasNoRows", () => {
  expect(parseDelimited("", ",", MAX_ROWS)).toEqual({ rows: [], totalRows: 0 });
});
test("capsRowsAndReportsTotal", () => {
  const text = Array.from({ length: 12 }, (_, i) => `r${i}`).join("\n");
  const t = parseDelimited(text, ",", 5);
  expect(t.rows.length).toBe(5);
  expect(t.totalRows).toBe(12);
});
test("an unclosed quote is an error on its line", () => {
  expect(parseDelimited('a\n"b,c', ",", MAX_ROWS).error).toBe("line 2: unclosed quote");
});
test("fieldAtCountsCharacters", () => {
  const t = parseDelimited("é,b\nc,d", ",", MAX_ROWS);
  expect(fieldAt(t, 1, 2)).toEqual({ row: 0, column: 1 });
  expect(fieldAt(t, 2, 0)).toEqual({ row: 1, column: 0 });
});
test("fieldAt inside a multi-line quoted field finds its row", () => {
  const t = parseDelimited('x,"a\nb"\ny,z', ",", MAX_ROWS);
  expect(fieldAt(t, 2, 0)).toEqual({ row: 0, column: 1 });
});
// follow.test.ts
test("innermost block containing the line", () => {
  expect(blockForLine([{ start: 1, end: 10 }, { start: 3, end: 4 }], 4)).toBe(1);
});
test("between blocks picks the one above", () => {
  expect(blockForLine([{ start: 1, end: 1 }, { start: 5, end: 6 }], 3)).toBe(0);
});
test("before the first block picks the first", () => {
  expect(blockForLine([{ start: 3, end: 4 }], 1)).toBe(0);
});
test("no blocks", () => { expect(blockForLine([], 1)).toBe(-1); });
```

- [ ] **Step 2: Run, expect failure:** `cd web && bun install && bun test` → module not found.
- [ ] **Step 3: Implement `csv.ts` and `follow.ts`.** Columns count characters (iterate by code point, not UTF-16 unit) so that they match nvim's `charcol`.
- [ ] **Step 4: Run, expect pass:** `cd web && bun test`
- [ ] **Step 5: Commit:** `git add web .gitignore && git commit -m "Renderer page: Bun project, CSV/TSV parsing, cursor-to-block mapping"`

---

### Task 7: Markdown rendering

**Files:**
- Create: `web/src/markdown.ts`, `web/test/markdown.test.ts`

**Interfaces:**
- Consumes: `Block` from `follow.ts`.
- Produces:
  ```ts
  export function renderMarkdown(text: string): string
  // Every top-level and nested block element (p, h1-h6, li, blockquote, pre, table, tr, hr)
  // carries data-source-start / data-source-end (1-based, inclusive).
  // ```mermaid fences become <div class="mermaid" data-source-start.. data-source-end..>source</div> (escaped text).
  // Other fences: <pre><code class="language-x">…</code></pre>.
  // markdown-it options: html: true, linkify: true, typographer: false.
  ```

- [ ] **Step 1: Write the failing tests**

```ts
test("blocks carry their source lines", () => {
  const html = renderMarkdown("# Title\n\nPara one\nstill one\n\n- a\n- b\n");
  expect(html).toContain('<h1 data-source-start="1" data-source-end="1">');
  expect(html).toContain('<p data-source-start="3" data-source-end="4">');
  expect(html).toContain('<li data-source-start="7" data-source-end="7">');
});
test("table rows carry lines", () => {
  const html = renderMarkdown("| a |\n|---|\n| 1 |\n| 2 |\n");
  expect(html).toContain('<tr data-source-start="4" data-source-end="4">');
});
test("mermaid fences become diagrams", () => {
  const html = renderMarkdown("```mermaid\ngraph TD; A-->B\n```\n");
  expect(html).toMatch(/<div class="mermaid" data-source-start="1" data-source-end="3">graph TD; A--&gt;B\n?<\/div>/);
});
test("raw HTML is passed through (the page's CSP keeps it static)", () => {
  expect(renderMarkdown("<details><summary>x</summary>y</details>")).toContain("<details>");
});
```

- [ ] **Step 2: Run, expect failure:** `cd web && bun test markdown`
- [ ] **Step 3: Implement.** Use a core rule that copies `token.map` onto `*_open` block tokens as attributes (`map[0] + 1`, `map[1]`). Override the `fence` renderer for `info === "mermaid"`. A table row's `map` comes from `tr_open`.
- [ ] **Step 4: Run, expect pass:** `cd web && bun test`
- [ ] **Step 5: Commit:** `git commit -am "Renderer page: markdown with source lines and mermaid fences"` (after `git add web/src/markdown.ts web/test/markdown.test.ts`)

---

### Task 8: JSON / YAML trees

**Files:**
- Create: `web/src/tree.ts`, `web/test/tree.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface TreeNode {
    path: string;              // stable id: "$", "$.a", "$.a[2]", "$['odd key']"
    key: string | null;        // property name or "[i]"; null for the root
    kind: "object" | "array" | "scalar";
    value?: string;            // scalars: display text (strings quoted, as in JSON)
    count?: number;            // objects/arrays: number of children
    start: number; end: number; // 1-based source lines
    children: TreeNode[];
  }
  export interface TreeResult { root: TreeNode | null; error?: string }   // error like "line 3: unexpected end"
  export function buildJsonTree(text: string): TreeResult   // jsonc-parser parseTree; comments allowed
  export function buildYamlTree(text: string): TreeResult   // yaml parseDocument with ranges; first document only
  export const AUTO_OPEN_DEPTH = 2                          // root is depth 0; depths 0 and 1 start open
  export function startsOpen(node: TreeNode, depth: number): boolean
  export function pathToLine(root: TreeNode, line: number): string[]  // paths from root to the deepest node whose lines contain `line`
  ```

- [ ] **Step 1: Write the failing tests**

```ts
test("JSON nodes with lines", () => {
  const { root } = buildJsonTree('{\n  "a": [1,\n    2],\n  "b": "x"\n}');
  expect(root!.kind).toBe("object");
  expect(root!.children.map(c => c.key)).toEqual(["a", "b"]);
  const a = root!.children[0];
  expect([a.start, a.end, a.count]).toEqual([2, 3, 2]);
  expect(a.children[1]).toMatchObject({ path: "$.a[1]", key: "[1]", value: "2", start: 3 });
  expect(root!.children[1].value).toBe('"x"');
});
test("odd keys get bracket paths", () => {
  expect(buildJsonTree('{"a b": 1}').root!.children[0].path).toBe("$['a b']");
});
test("broken JSON reports a line", () => {
  expect(buildJsonTree('{\n "a": 1,\n').error).toMatch(/^line 3: /);
});
test("emptyTextIsNotAnError", () => {
  expect(buildJsonTree("")).toEqual({ root: null });
  expect(buildYamlTree("")).toEqual({ root: null });
});
test("YAML nodes with lines", () => {
  const { root } = buildYamlTree("a:\n  - 1\n  - 2\nb: x\n");
  expect(root!.children.map(c => [c.key, c.start])).toEqual([["a", 1], ["b", 4]]);
  expect(root!.children[0].children[1]).toMatchObject({ path: "$.a[1]", start: 3 });
});
test("broken YAML reports a line", () => {
  expect(buildYamlTree("a: [1,\nb: 2\n").error).toMatch(/^line \d+: /);
});
test("open by depth", () => {
  const { root } = buildJsonTree('{"a":{"b":{"c":1}}}');
  expect(startsOpen(root!, 0) && startsOpen(root!.children[0], 1)).toBe(true);
  expect(startsOpen(root!.children[0].children[0], 2)).toBe(false);
});
test("path to the cursor's node", () => {
  const { root } = buildJsonTree('{\n "a": {\n  "b": 1\n }\n}');
  expect(pathToLine(root!, 3)).toEqual(["$", "$.a", "$.a.b"]);
});
```

- [ ] **Step 2: Run, expect failure:** `cd web && bun test tree`
- [ ] **Step 3: Implement.** Compute line numbers from offsets with a precomputed line-start table. YAML scalars display as JSON would (`JSON.stringify` for strings).
- [ ] **Step 4: Run, expect pass:** `cd web && bun test`
- [ ] **Step 5: Commit:** `git commit -m "Renderer page: JSON and YAML trees with source lines"` (after `git add`)

---

### Task 9: The renderer page, bundled into the app

**Files:**
- Create: `web/index.html`, `web/page.css`, `web/src/page.ts`, `web/build.ts`
- Modify: `Package.swift` (add `resources: [.copy("Resources/Preview")]` to the `Scwrote` target), `install.sh` (before `swift test`, run `(cd web && bun install --frozen-lockfile && bun test && bun run build)`)

**Interfaces:**
- Consumes: `renderMarkdown`, `parseDelimited`/`fieldAt`/`MAX_ROWS`, `build*Tree`/`startsOpen`/`pathToLine`, `blockForLine`.
- Produces the page API that Task 10 calls with `callAsyncJavaScript`:
  ```ts
  type Kind = "markdown" | "csv" | "tsv" | "mermaid" | "svg" | "json" | "yaml";
  interface RenderRequest { kind: Kind; text: string; baseURL: string; cursor: { line: number; column: number } }
  interface Theme { background: string; foreground: string; dim: string; selection: string;
                    accent: string; warning: string; divider: string; fontFamily: string; fontSize: number; isDark: boolean }
  window.scwrote = {
    render(req: RenderRequest): Promise<void>,   // replaces content only on success, then follow(req.cursor)
    follow(cursor): void,
    command(name: "lineDown"|"lineUp"|"halfPageDown"|"halfPageUp"|"top"|"bottom"|"open"|"close"|"toggle"): void,
    setTheme(theme: Theme): void,
  }
  // To Swift: webkit.messageHandlers.scwrote.postMessage(
  //   { type: "rendered", note?: string } | { type: "error", message: string })
  ```
- `build.ts` writes `Sources/Scwrote/Resources/Preview/`: `index.html`, `page.css`, `page.js` (`Bun.build`, target browser, minified), and `mermaid.min.js` copied from `node_modules/mermaid/dist/`.

Page behavior:
- `index.html` has a CSP meta tag: `default-src 'none'; script-src scwrote-app:; style-src scwrote-app: 'unsafe-inline'; img-src scwrote-app: scwrote-file: data: blob:; font-src scwrote-app: scwrote-file: data:`. It loads `mermaid.min.js` and `page.js`. Keep `'unsafe-inline'` and `'unsafe-eval'` out of `script-src`. If mermaid can't work without some other directive, add only that directive and note why in `index.html`.
- **Markdown:** set `<base href=baseURL>`, insert `renderMarkdown` output, then run `mermaid.run` on `.mermaid` nodes. A diagram that fails shows its source in a `pre` and posts an error. Clicks on `#fragment` links scroll within the page instead of navigating.
- **CSV/TSV:** a `<table>` with a sticky header row and one `tr` per record (`data-row`). When `totalRows > rows.length`, the note is `showing ${rows.length.toLocaleString("en-US")} of ${totalRows.toLocaleString("en-US")} rows`.
- **Mermaid file:** `mermaid.parse` first. On failure, post an error and keep the previous SVG.
- **SVG:** `<img src=blob:…>` from the text, so scripts in the SVG never run.
- **JSON/YAML:** nested rows with a disclosure triangle, the key, and a value or `{3}`/`[5]` summary. The open/closed state is kept per `path` across re-renders. New nodes start with `startsOpen`.
- **Errors:** any error, or a tree/table `error`, posts `{type:"error"}` and leaves the DOM as it was.
- **follow:** markdown scrolls the block from `blockForLine` (built from `[data-source-start]`) to center if it's off screen, and marks it with class `cursor-block` (a faint left-margin bar in `--accent`). CSV highlights the row and scrolls the cell into view horizontally. Trees open the nodes along `pathToLine` and highlight the last one. Mermaid and SVG do nothing.
- **command:** scrolls the page by a line (1.5em), half a page, or to the top/bottom. In a tree it moves the selection between visible rows, opens/closes the selection, and toggles it.
- **Theme:** CSS custom properties `--bg --fg --dim --selection --accent --warning --divider --font --font-size`. Mermaid initializes with `theme: "base"` and `themeVariables` taken from the theme (`darkMode: isDark`). Use `startOnLoad: false` and `securityLevel: "strict"`.

- [ ] **Step 1: Write a failing smoke test** `web/test/build.test.ts`. It runs `build.ts` into a temp dir (accept an output-dir argument), then asserts that `index.html`, `page.js`, `page.css` and `mermaid.min.js` exist and that `index.html` contains `script-src scwrote-app:` without `unsafe-inline` in the `script-src` directive.
- [ ] **Step 2: Run, expect failure:** `cd web && bun test build`
- [ ] **Step 3: Implement** `index.html`, `page.css`, `page.ts` and `build.ts` per the behavior above. Then change `Package.swift` and `install.sh`.
- [ ] **Step 4: Run, expect pass:** `cd web && bun test && bun run build && cd .. && swift build`. The build must succeed, with `.build/debug/Scwrote_Scwrote.bundle/Preview/page.js` present (the bundle name may differ; check `ls .build/debug/*.bundle`).
- [ ] **Step 5: Commit:** `git add web Package.swift install.sh && git commit -m "Renderer page: DOM rendering, theme, keys and bundling into the app"`

---

### Task 10: The preview pane view

**Files:**
- Create: `Sources/Scwrote/Preview/PreviewSchemeHandler.swift`, `Sources/Scwrote/Preview/PreviewHeaderView.swift`, `Sources/Scwrote/Preview/PreviewPaneView.swift`
- Modify: `Sources/Scwrote/Theme.swift` (add `warning: NSColor`, palette index 3 with fallback `.systemYellow`, and `static func css(_ color: NSColor) -> String` returning `#rrggbb`), `Sources/Scwrote/FileBrowserView.swift` (make `browserKey(for:)` `static` with internal access)

**Interfaces:**
- Consumes: `PreviewState`, `PreviewHeader`, `PreviewKind`, `PreviewURL`, `PreviewKeyReader`/`PreviewCommand`, `CursorPosition`, and the page API from Task 9.
- Produces:
  ```swift
  @MainActor final class PreviewPaneView: NSView {
      init(theme: Theme)
      var onLeave: (() -> Void)?                // Esc
      var onClick: (() -> Void)?                // focus into the pane
      var onOpenLink: ((String) -> Void)?       // a local path clicked in a markdown/HTML preview
      var onRendered: ((_ error: String?, _ note: String?) -> Void)?
      func show(_ state: PreviewState)          // re-renders the body for the current target and kind
      func showHeader(_ header: PreviewHeader)
      func follow(_ cursor: CursorPosition, lineCount: Int)
      func reloadFromDisk()                     // view-only files changed on disk
      func snapshot() async -> NSImage?         // for DebugHooks
  }
  @MainActor final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
      init(appResources: URL)                   // Bundle.module.resourceURL!.appending(path: "Preview")
      var overlay: (path: String, text: String)?   // the shown buffer's unsaved text, served in place of the file
  }
  ```

Behavior:
- **Header** (`PreviewHeaderView`): one row in the theme font and colors. The left side shows `header.label`. The right side shows `● unsaved` in `warning` when `isUnsaved`, and otherwise `message` (prefixed `⚠ ` in `warning` when `isError`, in `dim` otherwise). When both apply, show unsaved first, then the message. A 3 pt stripe in `warning` runs down the pane's left edge while `isUnsaved`.
- **Body by kind:**
  - `rendersInPage`: the document web view, which loads `PreviewURL.appIndex` once. Then `callAsyncJavaScript("await scwrote.render(req)", arguments: ["req": …])` with `baseURL = PreviewURL.folder(of:)` and `setTheme` on load.
  - `.html`: the second web view, with `defaultWebpagePreferences.allowsContentJavaScript = false`. Set `overlay` to the buffer text and load `PreviewURL.file(path)`.
  - `.image`: `NSImageView` in an `NSScrollView`, scaled down to fit and never up.
  - `.pdf`: `PDFView` with `autoScales = true`.
  - `.unsupported` or a buffer with nil text: an empty view in the theme background.
- **Scheme handler:** `scwrote-app:` serves files under `appResources`. `scwrote-file:` serves `overlay.text` for `overlay.path`, and otherwise the file on disk, with the MIME type from `UTType(filenameExtension:)?.preferredMIMEType`. A missing file gives a 404 response. Both web views share one handler instance.
- **Links:** a `WKNavigationDelegate` on both views. For `.linkActivated`: a `scwrote-file` URL calls `onOpenLink(path)`; `http`, `https` and `mailto` go to `NSWorkspace.shared.open`; everything is cancelled after that. The first load of each view is allowed.
- **Messages:** a `WKScriptMessageHandler` named `scwrote` forwards `rendered`/`error` to `onRendered`.
- **Following:** the document view calls `scwrote.follow`. The HTML view evaluates a proportional scroll using the fraction `(line - 1) / max(lineCount - 1, 1)` of the scrollable height. App-evaluated JavaScript still runs while content JavaScript is off.
- **Keys:** the pane accepts first responder. `keyDown` → `FileBrowserView.browserKey(for:)` → `PreviewKeyReader`. `.leave` calls `onLeave`; other commands go to `scwrote.command` on the document view, and become scroll calls on the HTML view (evaluated JS), the image scroll view, and the PDF view.
- **Theme:** `setTheme` gets `Theme.css` values. `isDark` is the background's luminance below 0.5.

- [ ] **Step 1: Build check before any wiring:** `cd web && bun run build && cd .. && swift build` passes with the new files. There's no unit test target for AppKit views; this task's behavior is verified in Task 11 through the debug hooks.
- [ ] **Step 2: Implement the three files and the `Theme`/`FileBrowserView` changes.**
- [ ] **Step 3: Run:** `swift build && swift test` (all pass).
- [ ] **Step 4: Commit:** `git add Sources/Scwrote && git commit -m "Add the preview pane view: header, web views, image and PDF views"`

---

### Task 11: Wire it into the window

**Files:**
- Modify: `Sources/Scwrote/EditorLayoutView.swift`, `Sources/Scwrote/EditorWindowController.swift`, `Sources/Scwrote/MainMenu.swift`, `Sources/Scwrote/DebugHooks.swift`
- Create: `Sources/Scwrote/EditorWindowController+Preview.swift`

**Interfaces:**
- Consumes: everything above.
- `EditorLayoutView` gains `previewView: PreviewPaneView`, `var layout: PaneLayout` (in place of `mode`), and stored `browserWidth`/`previewWidth` (defaults from `PaneFrames`). `layout()` applies `PaneFrames.compute`. There are two draggable dividers: the preview's divider sets `previewWidth = bounds.width - x`. It reports `var onGaveWay: ((Set<PaneLayout.Pane>) -> Void)?` after each layout where `gaveWay` changed.
- Controller additions: `previewState: PreviewState`, an `NvimEventListener` started in `init` and stopped in `windowWillClose`, and these actions:
  - `@objc func togglePreview(_:)` (Cmd+2)
  - `@objc func moveToLeftPane(_:)` (Cmd+[; replaces `goToFileBrowser`)
  - `@objc func moveToRightPane(_:)` (Cmd+]; replaces `goToEditor`)

Wiring rules:
- Listener events hop to the main actor. Then `previewState.apply`, and dispatch on the effect: `.render` → `previewView.show`, then `showHeader`, then `follow` (a render includes the snapshot's cursor). `.headerOnly` → `showHeader`. `.follow(c)` → `previewView.follow(c, lineCount:)` **only when the preview is shown and `panes.focus != .preview`**. `lineCount` is counted from the target's text.
- `previewView.onRendered` → `previewState.rendered`, then `showHeader`.
- Browser `.open(path)`: if `PreviewKind(path:).isViewOnly`, call `change { $0.openedViewOnlyFile() }`, then `previewState.pickViewOnly(path)` and `show`. Otherwise keep the existing nvim `:edit` path.
- Whenever focus moves to `.editor` (in `change`, comparing old and new focus), call `previewState.returnToEditor()` and render if needed.
- `previewView.onOpenLink(path)`: a view-only kind goes the same way as a browser pick of a view-only file; otherwise use the existing `open(path)`.
- `previewView.onLeave` → `change { $0.leavePreview() }`. `previewView.onClick` → `change { $0.clicked(.preview) }`.
- `layoutView.onGaveWay` → for each pane, `change { $0.paneGaveWay(pane) }`.
- The `FolderWatcher` callback also calls `previewView.reloadFromDisk()` when the target is `.viewOnly`.
- `applyPanes` makes `previewView` first responder when `focus == .preview`.
- Menu (View): "Toggle Preview" ⌘2. Rename the bracket items to "Move to Left Pane" ⌘[ and "Move to Right Pane" ⌘].
- DebugHooks:
  - Add `<D-2>` (keyCode 19, Cmd).
  - Add `{…}`: text between braces is sent to nvim with `nvim_input`. For example, `{ohello<Esc>}`.
  - The snapshot draws the preview pane from `await previewView.snapshot()` (web views via `takeSnapshot`) at its frame, plus the dividers.

- [ ] **Step 1: Implement the layout view and controller changes.**
- [ ] **Step 2: Build and test:** `cd web && bun run build && cd .. && swift build && swift test`
- [ ] **Step 3: Verify in the app** (`swift build -c release`, then run `bin/scwrote`). Each command saves a picture; open it and check what's listed:
  - `SCWROTE_DEBUG_KEYS='<D-2>' SCWROTE_DEBUG_SNAPSHOT=/tmp/p1.png bin/scwrote README.md`: rendered markdown on the right in theme colors, with the header `README.md · Markdown`.
  - `SCWROTE_DEBUG_KEYS='<D-2><D-[>{Go# New heading}' SCWROTE_DEBUG_SNAPSHOT=/tmp/p2.png bin/scwrote README.md`: `● unsaved` and the stripe show, and the new heading is **not** rendered yet (still in insert mode).
  - The same keys with `<Esc>}` added: the new heading is rendered.
  - A CSV fixture with `{3G}`: the third row is highlighted.
  - `SCWROTE_DEBUG_KEYS='<D-1>' …` on a folder with a PNG, after moving to it with `j`s and `<CR>`: the image shows in the preview, the browser stays open, and nvim is unchanged.
  - **`markdownPageNeverRunsInlineScript`:** a fixture `xss.md` containing `<img src="nope" onerror="document.body.style.background='red'">` and `<script>document.body.style.background='red'</script>`. The snapshot's preview background is the theme color, not red.
  - Narrow window: a snapshot after shrinking (or a fixture window width, if the hooks don't resize) shows the browser giving way first.
- [ ] **Step 4: Commit:** `git add -A Sources/Scwrote && git commit -m "Wire the preview pane into the window: Cmd+2, pane moves, nvim events"`

---

### Task 12: Docs and install

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README.**
  - Add a "Preview" section: what it shows per format, when it redraws (on Esc and normal-mode edits, not while typing), the unsaved header, cursor following, view-only files from the browser, static-only HTML, and links.
  - Key tables: Cmd+2, Cmd+[ / Cmd+] as left/right moves, and the keys inside the preview.
  - Build: Bun is now required (`brew install oven-sh/bun/bun`). `./install.sh` runs `bun install`, `bun test` and `bun run build`. Running `swift build` alone needs `cd web && bun run build` first.
  - Layout: add `web/`.
  - Debugging: `<D-2>` and `{…}` nvim input.
- [ ] **Step 2: Full install run:** `./install.sh && scwrote README.md`, then press Cmd+2 by hand and check the preview.
- [ ] **Step 3: Commit:** `git commit -am "README: the preview pane"`
