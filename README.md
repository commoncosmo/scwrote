# scredit

A native macOS editor shell: a Ghostty-rendered window running your nvim.

```bash
scredit README.md
scredit ./
scredit ./source/testrepo/README.md
```

`scredit <files>` behaves like `nvim <files>` typed in the same shell: same
arguments, same working directory, same environment (`PATH` and all). With a
folder, or no argument, it opens a file browser on that folder instead, and the
folder becomes nvim's working directory. The window uses your Ghostty config
(font, theme) and closes when nvim exits.

## File browser

Fills the window when you start on a folder; choosing a file opens it in nvim
and hides the browser. Pinned, it stays beside the editor.

Moving between the browser and the editor works from either pane, the way
Cmd+[ and Cmd+] move between splits in Ghostty and iTerm2:

| Key | Does |
|---|---|
| Cmd+[ | go to the browser, showing it if hidden |
| Cmd+] | go to the editor (hides the browser unless pinned) |
| Esc (in the browser) | same as Cmd+] |
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

Files open through nvim's RPC socket (scredit starts nvim with `--listen`),
using `:edit`. The tree follows changes on disk.

## Build and install

Requires macOS 27, Xcode 27, and Neovim (`brew install neovim`).

```bash
./install.sh                  # test, build, install to ~/.local
PREFIX=/opt/me ./install.sh   # or somewhere else
```

This puts the command at `~/.local/bin/scredit` and the app (binary plus the
resource folder libghostty loads from beside it) in `~/.local/share/scredit/`.
The installed copy doesn't depend on the repo; run `./install.sh` again to
update it. Day-to-day loop: `./install.sh && scredit README.md`.

Without installing, `swift test` runs the unit tests, and `bin/scredit` from
the repo runs the latest `swift build -c release`.

## Layout

- `bin/scredit`: launcher. Runs the app binary directly (not via `open`) so it
  inherits the shell's environment and working directory.
- `install.sh`: tests, builds, and installs the launcher and app under `PREFIX`.
- `Sources/ScreditCore`: pure logic, unit tested: argument handling, Ghostty
  config loading, finding `nvim` on `PATH`, the file browser and its keys,
  pane show/hide/pin rules, MessagePack and the nvim RPC client (tested
  against a real headless nvim).
- `Sources/Scredit`: the AppKit app: one window per process, hosting a
  libghostty surface ([libghostty-spm](https://github.com/Lakr233/libghostty-spm),
  pinned exactly because libghostty's API isn't stable yet).

## Debugging

`SCREDIT_DEBUG=1 scredit README.md` logs libghostty's lifecycle and actions to
`~/Library/Logs/scredit.log`.

To check the window without touching it, press keys and save a picture:

```bash
SCREDIT_DEBUG_KEYS='G<CR>' SCREDIT_DEBUG_SNAPSHOT=/tmp/shot.png scredit ./
```

Keys go to the browser; `<CR>` `<Esc>` `<Up>` `<Down>` `<Left>` `<Right>`
`<C-d>` `<C-u>` are named keys. The window's own keys, `<D-1>` (Cmd+1),
`<D-S-1>`, `<D-[>` and `<D-]>`, are posted as real key events, so they take
the same path through the app as a keyboard's.

## Known quirks

- macOS only lets a new app take focus while it still descends from the app
  you're typing in. So the launcher waits (up to 5 seconds) until scredit
  signals it's in front, via SIGUSR1 to `SCREDIT_NOTIFY_PID`, before giving
  the prompt back. If it exited at once, the window would open behind your
  terminal.
- The nvim command is passed through Ghostty's config, not the surface's
  `command` option: libghostty forces `wait-after-command` on for surface
  commands, which would leave the window at "Process exited" after `:q`.
- libghostty-spm layers a default theme over any config unless given an empty
  `TerminalTheme()`; scredit passes an empty one so your Ghostty theme wins.
