# scredit

A native macOS editor shell: a Ghostty-rendered window running your nvim.

```bash
scredit README.md
scredit ./
scredit ./source/testrepo/README.md
```

`scredit <args>` behaves like `nvim <args>` typed in the same shell: same
arguments, same working directory, same environment (`PATH` and all). The window
uses your Ghostty config (font, theme) and closes when nvim exits.

## Build and install

Requires macOS 27, Xcode 27, and Neovim (`brew install neovim`).

```bash
swift build -c release
ln -s "$PWD/bin/scredit" ~/.local/bin/scredit   # any folder on your PATH
swift test                                      # unit tests for ScreditCore
```

## Layout

- `bin/scredit`: launcher. Runs the app binary directly (not via `open`) so it
  inherits the shell's environment and working directory.
- `Sources/ScreditCore`: pure logic, unit tested: argument handling, Ghostty
  config loading, finding `nvim` on `PATH`.
- `Sources/Scredit`: the AppKit app: one window per process, hosting a
  libghostty surface ([libghostty-spm](https://github.com/Lakr233/libghostty-spm),
  pinned exactly because libghostty's API isn't stable yet).

## Debugging

`SCREDIT_DEBUG=1 scredit README.md` logs libghostty's lifecycle and actions to
`~/Library/Logs/scredit.log`.

## Known quirks

- The nvim command is passed through Ghostty's config, not the surface's
  `command` option: libghostty forces `wait-after-command` on for surface
  commands, which would leave the window at "Process exited" after `:q`.
- libghostty-spm layers a default theme over any config unless given an empty
  `TerminalTheme()`; scredit passes an empty one so your Ghostty theme wins.
