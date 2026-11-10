# Preview pane: open issues to revisit

Collected from the per-task and whole-branch reviews of the preview pane
(branch `preview-pane`, through 3945e7b). Nothing here blocks use. File and
line references are as of that commit and will drift.

Issues already fixed during the review rounds are left out.

## Check by hand

- [ ] **Click to focus.** Click into a markdown preview, a PDF, and an image,
  then press `j`: each should scroll. Agents couldn't bring the app to the
  front, so this was never verified.
- [ ] **First Cmd+2.** Watch for a blank flash before the first render. One
  installed-copy snapshot ~1 s after Cmd+2 showed an empty body; a later one
  was complete. Possibly first paint of a web view that had zero size.

## Worth fixing soon

- [ ] **Wrong body under a new file's header while waiting for text.** Preview
  hidden, `:e b.md`, focus a sidebar/terminal/help window in nvim, Cmd+2: the
  header says `b.md` over the previous file's render (or an empty body) until
  you enter a real file. The re-send on show sends nothing when nvim's current
  window isn't a real file. Fix: in the waiting branch
  (`EditorWindowController+Preview.swift`, `renderPreview`), clear the body
  when the target path differs from the last rendered path; or have the
  install also send the last real-file buffer.
- [ ] **JSON accepts trailing commas** (`web/src/tree.ts`, `allowTrailingComma:
  true`), which hides a real error in a plain `.json` file. Allow them only
  for `.jsonc`.
- [ ] **App's own nvim client gives up after 5 s** on a slow nvim startup, so
  opening a file from the browser beeps instead of waiting
  (`EditorWindowController`, `NvimClient` 5 s `SO_RCVTIMEO`). The listener
  already waits this out.

## Remote content in HTML previews

Added in a1b0e78 (blocked until you press R, per file). Review found no
leaks; these are hardening and UX gaps.

- [ ] **Header click can grant consent when the note is cut off.** In a
  narrow pane the clickable area clamps to the status start, so a click on
  "● unsaved" or a message can count as "load". Put the note first, or make
  it clickable only when drawn in full (`PreviewHeaderView.swift`).
- [ ] **Force-click link preview** bypasses the lockdown (`allowsLinkPreview`
  is on by default). Set it to false on the HTML view.
- [ ] **DNS prefetch unverified.** Add `X-DNS-Prefetch-Control: off` to
  `scwrote-file` HTML responses as cheap insurance.
- [ ] **Scan gaps leave content blocked with no note:** `background=`
  attributes, SVG `<image href>` / `xlink:href`, `<use href>`,
  `<link rel=preload>`, `<track src>`, `image-set()` with bare strings, and
  `@import` nested inside a local imported sheet.
- [ ] **The note can promise loads that never happen:** iframes, `<embed>`,
  `<object>` (child frames are always cancelled) and protocol-relative
  `//host/x` (404s by design) set the note, but R changes nothing for them.
  Drop them from the scan or say so in the README. `javascript:`/`mailto:`
  in `src` also count as remote.
- [ ] Header text says "R to load" though a click and the View menu work
  too.
- [ ] The content rule list is recompiled on every launch;
  `lookUpContentRuleList` first would skip that.
- [ ] Markdown never loads remote images (the page's CSP). Decide whether it
  should get the same gate.

## Narrow windows

- [ ] A preview that is shown but squeezed out still asks nvim for text on
  every edit; key text on/off to "shown and not given way".
- [ ] A squeezed-out preview still renders at zero size, and widening the
  window doesn't re-follow the cursor until the next cursor move.
- [ ] `onGaveWay` runs synchronously inside `EditorLayoutView.layout()`;
  deferring it a tick would be more robust.
- [ ] `PaneFrames.swift`: a local `browserWidth` shadows the parameter in the
  `.browserOnly` branch (reads like a bug).

## Renderer page (`web/`)

- [ ] JSON parse errors show raw jsonc codes (`PropertyNameExpected`) rather
  than prose.
- [ ] YAML errors repeat the position ("line 2: … at line 2, column 1:").
- [ ] Duplicate JSON keys produce duplicate tree paths; non-scalar YAML keys
  display as `[object Object]`.
- [ ] CSV: a blank line mid-file yields a one-empty-field row; `"" "x"` reopens
  quoting; no BOM strip (nvim usually strips it).
- [ ] After `setTheme` re-renders, a request that had failed is re-rendered
  and re-posts its error (`lastRequest` is set before success).
- [ ] While the preview has the keyboard, a render that arrives (timers,
  autocmds) still scrolls to the snapshot cursor at the end of render; the
  spec says following stops while the preview has focus.
- [ ] `build.ts` deletes whatever output directory it's given
  (`rmSync(outdir, {recursive, force})`); guard it.
- [ ] `select(undefined)` when `pathToLine` returns `[]` (harmless, unsound
  type).
- [ ] Fresh clone without `bun run build` fails `swift build` with an unhelpful
  CpResource error (documented in the README); a clearer failure would help.

## Preview pane (AppKit)

- [ ] If the bundled page itself fails to load before any render, renders wait
  forever with no message (broken install only).
- [ ] The HTML view has no web-content-crash recovery (the document view does).
- [ ] A view-only HTML file that's missing shows a blank page and reports
  success.
- [ ] A PDF that changes on disk reloads at the top, losing the position.
- [ ] Images fit to width; with always-visible scrollers an image near the
  pane's height can make the vertical scroller flicker.
- [ ] The `gg` key state resets on every show (a pending `g` is lost when a
  view-only file reloads).
- [ ] Expected-load bookkeeping in `PreviewWebViews.swift`: an A, B, A sequence
  of HTML loads inside one IPC round trip can cancel the newest; a web-content
  crash can leave a stale count (clear it in `contentProcessDidTerminate`).
- [ ] Pure scroll/line-count math lives in the app target; it could move to
  `ScwroteCore` and get tests.
- [ ] `FolderWatcher` only watches the browser root, so a view-only file opened
  through a link outside it won't reload on change.
- [ ] The debug snapshot's PDF/web clipping assumes they're direct subviews.

## nvim connection

- [ ] The "lost nvim's events" log line probably prints on every normal `:q`
  (`EditorWindowController+Preview.swift`, `previewEventsEnded`).
- [ ] `charcol('.')` runs on every cursor move and is O(column); slow on huge
  single-line files (minified JSON).
- [ ] `NvimEventListener.start()` twice isn't guarded (two threads, `onEnd`
  twice).
- [ ] The slow-startup test adds ~6 s to `swift test`.

## Pane rules

- [ ] Before any file is open, with the preview focused, Cmd+1 does nothing
  (Cmd+[ and Esc recover).
- [ ] Moving left from the preview to the editor leaves an unpinned browser
  visible in split mode (matches the spec; worth a UX look).
- [ ] A file with an extension scwrote doesn't preview still uses nvim's
  filetype (`notes.txt` with `filetype=markdown` previews as markdown).
  Arguably right (modelines); undocumented.

## Test gaps

- [ ] `PreviewKind`: heif/tif/bmp/ico, filetypes yaml/jsonc/html/mermaid,
  every `displayName`.
- [ ] `PaneLayout`: `paneGaveWay` when unfocused or with no file,
  `leavePreview` when unfocused, `moveLeft` from the preview without a file,
  `clicked(.preview)`.
- [ ] `PaneFrames`: `.browserOnly` with the preview giving way, editor
  clamped to 0, an unpinned browser alone under 481 pt.
- [ ] `PreviewState`: same-path error retention, `returnToEditor` with no
  buffer, `rendered(nil, nil)`, `.cursor` while view-only.
- [ ] `PreviewURL` with relative paths (force-unwrap / wrong folder; callers
  always pass absolute paths).
- [ ] Markdown: non-mermaid fence `language-x`, nested blockquote, `<hr>`.
- [ ] `follow.ts`: equal-span tie-break, line after all blocks.
- [ ] No committed tests for the AppKit preview views; verification was by
  debug-hook snapshots.
