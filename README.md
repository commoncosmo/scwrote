# scwrote

A native macOS editor shell: a Ghostty-rendered window running your nvim.

```bash
scwrote README.md
scwrote ./
scwrote ./source/testrepo/README.md
```

`scwrote <files>` behaves like `nvim <files>` typed in the same shell: same
arguments, same working directory, same environment (`PATH` and all). With a
folder, or no argument, it opens a file browser on that folder instead, and the
folder becomes nvim's working directory. The window uses your Ghostty config
(font, theme) and closes when nvim exits.

## File browser

Fills the window when you start on a folder; choosing a file opens it in nvim
and hides the browser. Pinned, it stays beside the editor.

Moving between the browser and the editor works from either pane, the way
Cmd+[ and Cmd+] move between splits in Ghostty and iTerm2. With the preview
shown they move one pane at a time across all three (see Preview below):

| Key | Does |
|---|---|
| Cmd+[ | one pane left; from the editor, the browser, showing it if hidden |
| Cmd+] | one pane right; from the browser, the editor (hides the browser unless pinned) |
| Esc (in the browser) | go to the editor (hides the browser unless pinned) |
| Cmd+1 | show the browser and go to it / go to it / hide it |
| Cmd+Shift+1 | pin / unpin |

In the browser:

| Key | Does |
|---|---|
| `j` `k`, ↓ ↑ | move (counts work: `5j`) |
| `l`, → | open a folder, step into an open one, open a file |
| `h`, ← | close a folder, or jump to the folder you're in |
| Enter, `o` | open a file, or open/close a folder |
| `gg` `G` | top / bottom (`3G`: third row) |
| Ctrl-d Ctrl-u | half a page down / up |
| `-` | go up a folder |
| `gh` | show / hide dotfiles |

Files open through nvim's RPC socket (scwrote starts nvim with `--listen`),
using `:edit`. The tree follows changes on disk.

## Preview

A pane to the right of the editor that shows the file nvim is editing, drawn
from nvim's buffer, so unsaved text shows too. It appears only when you ask
for it, and stays until you hide it.

| Key | Does |
|---|---|
| Cmd+2 | show the preview and go to it / go to it / hide it |
| Cmd+] | move one pane right: browser, editor, preview |
| Cmd+[ | move one pane left: preview, editor, browser |
| Esc (in the preview) | back to the editor |

The window's menu has these too, as Toggle Preview, Move to Left Pane and Move
to Right Pane. The preview has no pin: leaving it doesn't hide it. In a narrow
window the unpinned browser gives way first, then the preview; they come back
when there's room. The pane you're in never gives way, nor does the preview
while you're in the browser: the editor narrows instead, so you can step
through images. Cmd+2 on a preview with no room hides it.

What it shows, by file extension (or nvim's `filetype` when the extension says
nothing):

| Format | Shows | Follows nvim's cursor by |
|---|---|---|
| Markdown (`.md`) | rendered page; ` ```mermaid ` blocks become diagrams | scrolling the block under the cursor into view |
| CSV, TSV (`.csv`, `.tsv`, `.tab`) | a table (first rows only for big files) | highlighting the cursor's row and column |
| JSON, YAML (`.json`, `.jsonc`, `.yaml`, `.yml`) | a collapsible tree | opening and highlighting the cursor's node |
| HTML (`.html`, `.htm`) | the page, as it is | proportional position |
| Mermaid (`.mmd`, `.mermaid`) | the diagram | not at all |
| SVG | the drawing | not at all |
| Images, PDF | the file, view-only | not at all |

Any other file keeps the pane open with "no preview" in the header.

**When it redraws.** On leaving insert mode and after normal-mode changes
(`dd`, `p`, `.`, undo, `:s`), when you switch buffers, and on save. Not while
you type. If the new text doesn't parse (half-finished JSON, a broken
diagram), the last good render stays and the header shows the error.

**The header** names the file and its kind. When the buffer has unsaved
changes it says "● unsaved" and a stripe runs down the pane's left edge; both
clear on `:w`.

**Which file.** The preview follows nvim's current buffer. Pickers, hovers,
help, quickfix and `:terminal` don't count; it keeps the last real file.
Choosing an image or PDF in the file browser shows it in the preview (even if
hidden) while nvim stays where it was, and focus stays in the browser so you
can step through with `j` and Enter. The preview goes back to nvim's buffer
when you return to the editor.

**HTML is static.** Its scripts never run. Relative CSS, images and fonts load
from the file's folder (so do relative images in markdown), and the page may
load remote images or CSS it references. scwrote's own renderers need no
network.

**Links.** A link to a local file opens it in nvim, as the browser would; a
web link opens your default browser.

In the preview:

| Key | Does |
|---|---|
| `j` `k`, ↓ ↑ | scroll (in a tree: move between nodes) |
| Ctrl-d Ctrl-u | half a page down / up |
| `gg` `G` | top / bottom |
| `l`, → / `h`, ← | open / close a tree node |
| Enter, `o` | open / close a tree node |
| Esc | back to the editor |

While the preview has focus it stops following nvim's cursor; it picks up
again when you return to the editor.

## Build and install

Requires macOS 27, Xcode 27, Neovim (`brew install neovim`) and Bun
(`brew install oven-sh/bun/bun`).

```bash
./install.sh                  # bun install/test/build, swift test/build, install to ~/.local
PREFIX=/opt/me ./install.sh   # or somewhere else
```

This puts the command at `~/.local/bin/scwrote` and the app (binary plus the
resource folder libghostty loads from beside it) in `~/.local/share/scwrote/`.
The installed copy doesn't depend on the repo; run `./install.sh` again to
update it. Day-to-day loop: `./install.sh && scwrote README.md`.

The preview's page is built with Bun and bundled into the app as a resource, so
a fresh clone needs it built before a plain `swift build` or `swift test`:

```bash
cd web && bun install && bun run build
```

Then `swift test` runs the unit tests (`cd web && bun test` the page's), and
`bin/scwrote` from the repo runs the latest `swift build -c release`.

## Layout

- `bin/scwrote`: launcher. Runs the app binary directly (not via `open`) so it
  inherits the shell's environment and working directory.
- `install.sh`: tests, builds, and installs the launcher and app under `PREFIX`.
- `Sources/ScwroteCore`: pure logic, unit tested: argument handling, Ghostty
  config loading, finding `nvim` on `PATH`, the file browser and its keys,
  pane show/hide/pin rules, MessagePack and the nvim RPC client (tested
  against a real headless nvim).
- `Sources/Scwrote`: the AppKit app: one window per process, hosting a
  libghostty surface ([libghostty-spm](https://github.com/Lakr233/libghostty-spm),
  pinned exactly because libghostty's API isn't stable yet).
- `Sources/Scwrote/Preview/`: the preview pane: header, web views, image and
  PDF views.
- `web/`: the preview's renderer page (TypeScript, built with Bun): markdown,
  tables, trees, mermaid. `bun test` tests it; `bun run build` bundles it into
  the app's resources.

## Debugging

`SCWROTE_DEBUG=1 scwrote README.md` logs libghostty's lifecycle and actions to
`~/Library/Logs/scwrote.log`.

To check the window without touching it, press keys and save a picture:

```bash
SCWROTE_DEBUG_KEYS='G<CR>' SCWROTE_DEBUG_SNAPSHOT=/tmp/shot.png scwrote ./
```

Keys go to the browser; `<CR>` `<Esc>` `<Up>` `<Down>` `<Left>` `<Right>`
`<C-d>` `<C-u>` are named keys. The window's own keys, `<D-1>` (Cmd+1),
`<D-S-1>`, `<D-2>`, `<D-[>` and `<D-]>`, are posted as real key events, so they take
the same path through the app as a keyboard's. Text in braces goes to nvim
(`nvim_input`, in nvim's key notation), so `{ohello<Esc>}` opens a line, types
"hello" and leaves insert mode. `SCWROTE_DEBUG_WIDTH=600` sets the window's
content width in points first, to see which panes give way:

```bash
SCWROTE_DEBUG_KEYS='<D-2>{ohello<Esc>}' SCWROTE_DEBUG_SNAPSHOT=/tmp/p.png scwrote README.md
```

## Known quirks

- macOS only lets a new app take focus while it still descends from the app
  you're typing in. So the launcher waits (up to 5 seconds) until scwrote
  signals it's in front, via SIGUSR1 to `SCWROTE_NOTIFY_PID`, before giving
  the prompt back. If it exited at once, the window would open behind your
  terminal.
- The nvim command is passed through Ghostty's config, not the surface's
  `command` option: libghostty forces `wait-after-command` on for surface
  commands, which would leave the window at "Process exited" after `:q`.
- libghostty-spm layers a default theme over any config unless given an empty
  `TerminalTheme()`; scwrote passes an empty one so your Ghostty theme wins.
