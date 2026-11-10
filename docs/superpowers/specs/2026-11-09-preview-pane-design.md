# Preview pane: design

Date: 2026-11-09
Status: approved 2026-11-09

## Intent

scwrote is a native macOS window running the user's own nvim (via libghostty)
with a vim-style file browser beside it. This adds a third pane, to the right
of the editor, that shows a rendered view of the file being edited.

The immediate need is **markdown and CSV**: writing a document or a data file
in nvim and seeing what it looks like without leaving the window. The other
formats come along in the same pass because they share the same machinery and
are cheap once it exists.

The preview should feel like it belongs to a vim user's editor: it follows
nvim (the buffer, the cursor), it redraws on vim's own notion of a finished
change (leaving insert mode), and it never competes with nvim for ownership of
the file.

## Goals

- A preview pane to the right of the editor: **browser | editor | preview**.
- Previews for:
  - **Markdown**, including fenced ` ```mermaid ` blocks rendered as diagrams
  - **CSV and TSV** as a table
  - **HTML**, static only (see below)
  - **Mermaid** files (`.mmd`, `.mermaid`)
  - **SVG**
  - **JSON and YAML** as a collapsible tree
  - **Images** (PNG, JPEG, GIF, WebP, and whatever else macOS shows natively)
    and **PDF**, as view-only files opened from the file browser
- The preview reads **nvim's buffer**, not the file on disk, so unsaved text is
  shown.
- The preview header says when the buffer has unsaved changes.
- The preview scrolls to follow nvim's cursor.

## Non-goals (for now)

- **Graphviz `.dot`, LaTeX, Typst.** They need external tools; add them when a
  need comes up.
- **Running JavaScript from the user's HTML.** The user is of two minds;
  static HTML and CSS only until revisited. (scwrote's own renderers may use
  JavaScript inside the preview; the rule is about scripts that come from the
  user's files.)
- **scwrote-specific light/dark themes.** The preview uses the Ghostty theme,
  like the file browser. Separate scwrote themes may come later; don't build
  for them now beyond keeping colors in one place.
- **Showing the preview automatically** when a previewable file opens.
- **AI editing.** Not part of this work, but see "Future: AI edits" for the
  model the preview should not get in the way of.

## Anti-goals

- **Never touch the file or nvim's state.** The preview only observes: no
  writes, no swap-file interaction, no changes to buffers, options, or undo
  history.
- **Never interrupt typing.** Nothing the preview does may lag or block nvim
  input. A slow render is the preview's problem, not the editor's.
- **Never go blank on bad input.** Half-finished JSON, a broken mermaid
  diagram, or malformed CSV keeps the last good render on screen with an
  error note; it does not wipe the pane.
- **Never need the network.** All renderers ship with the app.

## Behavior

### Showing and moving between panes

The preview appears only when asked for. Once shown, it stays shown as the
user moves between files, until hidden.

| Key | Does |
|---|---|
| Cmd+2 | show the preview and go to it / go to it / hide it (same pattern as Cmd+1 for the browser) |
| Cmd+[ | move one pane left (preview → editor → browser), showing the browser if needed, as today |
| Cmd+] | move one pane right (browser → editor → preview, if the preview is showing) |
| Esc (in the preview) | back to the editor |

*Builder's call (proposed in conversation, not explicitly confirmed):* the
preview has no pin. It doesn't hide when you leave it; only Cmd+2 hides it.
The browser's existing pin and hide-on-leave rules are unchanged.

Today `PaneLayout` models two panes (`browser`, `editor`) with modes
`browserOnly | split | editorOnly`. That needs to grow a third pane whose
visibility is independent of the browser's. `PaneLayout` is pure and unit
tested; keep it that way and extend its tests.

In the preview, with keyboard focus:

| Key | Does |
|---|---|
| `j` `k`, ↓ ↑ | scroll (in a tree: move between nodes) |
| Ctrl-d Ctrl-u | half a page down / up |
| `gg` `G` | top / bottom |
| `l` `h`, Enter (tree) | open / close a node |

While the preview has focus it stops following nvim's cursor; it picks up again
when focus returns to the editor.

Widths: the editor keeps most of the window. Each side pane has a draggable
divider like the browser's. When the window is too narrow for all three, the
unpinned browser gives way first, then the preview. (Exact minimums are the
builder's call; the existing browser uses 160 pt.)

*Assistant's call:* "giving way" is temporary. A pane squeezed out for lack of
room comes back by itself when the window is wide enough again. It is not
the same as the user hiding it, so the model needs to tell "hidden by the
user" apart from "doesn't fit". A pinned browser never gives way; with the
browser pinned, the preview goes first. If the pane that gives way has the
keyboard, focus moves to the editor.

### Which file the preview shows

- **By default, nvim's current buffer.** When nvim switches buffers, the
  preview follows.
  *Assistant's call:* only buffers that are real files count, meaning those
  with an empty `buftype` that sit in normal windows, not floating ones.
  Pickers (Telescope etc.), LSP hovers, completion menus, help, quickfix,
  `:terminal` and plugin sidebars are ignored, and the preview keeps
  showing the last real file. Otherwise the pane would flash to "no preview"
  every time a popup opens.
- **A view-only file (image, PDF) picked in the file browser** shows in the
  preview. nvim stays where it was; nothing opens in nvim. The user suspects
  the mismatch between nvim and the preview may bother them; build it this way
  first and keep it easy to change. The alternative being kept in reserve:
  the editor pane collapses, or shows a "view-only file" placeholder.
  Confirmed with the user:
  - Choosing a view-only file (Enter, `o`, `l`) **shows the preview even if
    it was hidden**. This is an explicit request to see it, so it doesn't
    conflict with "only when asked".
  - **Focus stays in the browser, and an unpinned browser stays open**, so
    `j`/`k` then Enter steps through images.
  - The preview **goes back to nvim's buffer** when focus returns to the
    editor (Esc, Cmd+], click) or when nvim switches to another real-file
    buffer.
  - **Before any file is open in nvim** (started on a folder), the preview
    opens beside the full-window browser. Esc and Cmd+] keep today's
    behavior (they do nothing until a file is open).
- **A file with no previewer** (e.g. Swift source): the pane stays open, the
  header reads "Main.swift · no preview", and the body is empty.

### When it redraws

The preview shows **nvim's buffer contents**. It redraws:

- when the user **leaves insert mode** (`InsertLeave`), and
- after **normal-mode changes** (`TextChanged`: `dd`, `p`, `.`, undo/redo,
  `:s`, etc.), and
- when the shown buffer changes (buffer switch, `:e`), and on save.

It does **not** redraw on each keystroke in insert mode. Reasons: it matches
vim's own unit of change (one insert session = one undo step), and it avoids
rendering half-typed syntax. A per-format "live while typing" option is a
plausible later addition (markdown is the obvious candidate); don't build it
now.

If the new content fails to parse, keep the last good render and show the
error in the header (e.g. "⚠ line 14: unexpected `}`").

Images and PDFs have no buffer: they're read from disk and re-read when the
file changes (scwrote already watches folders, see `FolderWatcher`).

### Following the cursor

As nvim's cursor moves (normal and insert mode; scrolling is cheap even though
redrawing waits), the preview keeps the matching part in view. If the user
scrolls the preview by hand, it stays put until the cursor next moves.

| Format | Follows by |
|---|---|
| Markdown | scrolling the block (heading, paragraph, list item, table row, code block) containing the cursor line into view, with a faint marker beside it |
| CSV / TSV | highlighting the cursor's row and keeping it in view, scrolling sideways to the cursor's column |
| JSON / YAML tree | opening the nodes down to the cursor's node and highlighting it; nodes the user collapsed by hand stay collapsed unless the cursor goes inside them |
| HTML | proportional position only (cursor line ÷ line count): there's no reliable source-line-to-element mapping |
| Mermaid, SVG, images, PDF | no following; shown whole |

### The header

A header bar runs across the top of the preview, always visible:

- left: file name and kind, e.g. `README.md · Markdown`, `logo.svg · SVG`,
  `photo.jpg · Image`, `Main.swift · no preview`
- right: `● unsaved` when the shown buffer has unsaved changes (nvim's
  `modified` flag), plus a colored stripe down the pane's left edge. Both clear
  on `:w`. View-only files never show it.
- errors (parse failures) and notes (large-file truncation) also go here.

This was chosen over a dismissable strip or a floating pill partly because it
also tells the user which file the preview is on, which matters when an image
picked in the browser differs from nvim's buffer.

### Look

Formats scwrote draws itself (markdown, tables, trees, mermaid, the header)
use the **Ghostty theme**: background, foreground, palette, and font, the same
way `Theme.swift` styles the file browser. HTML, SVG, images and PDFs show as
they are.

### HTML specifics

- Static HTML and CSS only: the user's scripts don't run.
- Relative CSS, images, and fonts load from the HTML file's folder.
- Same base-folder rule for relative images in markdown.

### Links

- Clicking a link to a **local file** (markdown or HTML) opens it in nvim, the
  same way as choosing it in the file browser; the preview follows.
- Clicking a **web link** opens the default browser. The preview never
  navigates away from the user's file.

### Large files

- CSV/TSV: render the first few thousand rows (exact cap is the builder's
  call); the header says "showing 5,000 of 182,340 rows".
- JSON/YAML: start collapsed beyond the first couple of levels.
- Nothing the preview does on a large file should make nvim feel slower.

## Constraints and existing code

- **Platform:** macOS 27, Swift 6.2 (language mode 6), AppKit, SwiftPM. One
  window per process.
- **Code split:** `ScwroteCore` is pure logic with no AppKit, unit tested
  (including `NvimClient` against a real headless nvim). `Scwrote` is the
  AppKit app. New pure logic (pane rules, format detection, CSV parsing,
  cursor-to-block mapping where it isn't in JS, event decoding) belongs in
  `ScwroteCore` with tests.
- **nvim connection:** scwrote starts nvim with `--listen` and talks to it via
  `NvimClient`, a **blocking request/response** client that currently skips
  notifications. The preview needs nvim to push events (buffer changes,
  cursor moves, mode changes, modified flag, buffer switches). nvim allows
  several clients on one `--listen` socket; how to receive events (a second
  connection dedicated to notifications, `nvim_buf_attach`, autocommands
  calling `rpcnotify`, or a mix) is the builder's call. Whatever it is, it must
  not slow nvim and must survive the user's own config (plugins, autocommands).
- **Shortcuts:** window keys are Cmd-only (`WindowShortcut`) because nvim never
  receives Cmd keys. Keep that.
- **Install layout:** `install.sh` puts the app and the resource bundle(s)
  libghostty loads from beside the binary under `$PREFIX/share/scwrote/`.
  Renderer assets need to ship the same way so the installed copy doesn't
  depend on the repo.
- **JavaScript tooling:** if any JS packages are fetched or built, use **Bun**
  (`bun`, `bunx`), never npm/npx/yarn/pnpm.
- **Debug hooks:** `SCWROTE_DEBUG_KEYS` / `SCWROTE_DEBUG_SNAPSHOT` drive the
  window headlessly. Extending them (e.g. `<D-2>`) makes the preview
  checkable the same way.
- **README** documents keys and layout; update it.

## Decided by the user

- Preview sits to the right of the editor.
- Formats in this pass: markdown, CSV, TSV, HTML, mermaid, SVG, JSON tree,
  YAML tree, images, PDF. `.dot`, LaTeX, Typst deferred.
- Preview reads the buffer; redraws on leaving insert mode and normal-mode
  edits, not per keystroke.
- Unsaved state shown via an always-present header with an unsaved marker
  and edge stripe (mockup option C).
- Preview follows nvim's cursor.
- Shown only when asked for.
- Theme colors from Ghostty, not a light page.
- HTML: static only; JS deferred.
- View-only files picked in the browser show in the preview while nvim stays
  put (try it; may revisit). Picking one shows the preview, focus stays in
  the browser, and returning to the editor points the preview back at nvim.

## Left to the builder

- Rendering technology. The assistant's suggestion: one `WKWebView` hosting a
  small local page with a renderer per format (markdown-it with source-line
  maps, mermaid, a YAML parser, hand-rolled CSV table and JSON/YAML tree), and
  PDFKit or the web view for PDFs. Any approach meeting the behavior above is
  fine.
- How assets are vendored and bundled.
- Event plumbing from nvim (see constraints).
- Pane minimum widths, default preview width, the CSV row cap, the
  JSON/YAML auto-collapse depth.
- File-type detection (extension, and nvim's `filetype` where helpful).

## Future: AI edits (context only, not in scope)

If AI editing is added later, the intended model is that AI changes go
**through nvim's buffer** over RPC, held until the user leaves insert mode,
so they join the undo history and show up in the preview exactly like the
user's own edits (including "unsaved"). The preview built here should rely
only on the buffer and nvim's events, so nothing about it needs to change for
that.
