# File actions in the browser: design

Date: 2026-11-09
Status: approved 2026-11-09

## Intent

The file browser can navigate and open files, but not create, rename or
delete them. Starting scwrote in an empty folder is a dead end: the browser
covers the window, nothing can be opened, and every way to reach nvim waits
for a file to be open. This adds nvim-tree-style file actions to the browser
and removes the dead end.

## Goals

- Reach the editor from an empty folder.
- Create a file or folder, naming it as you create it.
- Rename a file or folder.
- Delete a file or folder, after a confirmation.
- Keep nvim's buffers in step with renames and deletes.

## Non-goals

Copy, cut and paste; selecting several items; undoing renames. The Trash is
the undo for deletes.

## Anti-goals

- Never overwrite or lose a file: an existing name is an error, and deletes go
  to the Trash.
- Never act on a single stray keypress: deleting needs an explicit `y`.
- Never touch anything outside the browser's folder through `a` or `r`.

## Behavior

### Empty folders

- Esc and Cmd+] reach the editor even before a file is open (nvim's empty
  buffer works: `:e name.md`). After that, the browser behaves as it does once
  a file is open (it hides on leaving unless pinned; Cmd+1 can hide it).
- An empty folder's row reads `(empty) · a: new file`.

### Keys

| Key | Does |
|---|---|
| `a` | add a file or folder |
| `r` | rename the selected item |
| `d` | delete the selected item, after a confirmation |

`r` and `d` do nothing when nothing is selected (empty folder).

### The prompt

- Drawn on the browser's bottom row, like vim's command line. Enter confirms,
  Esc cancels.
- Editing: typing, Backspace, ← →, Ctrl-a / Ctrl-e (start / end), Ctrl-w
  (delete the word before the cursor), Ctrl-u (delete everything before the
  cursor).
- Errors show on that row (`notes.md already exists`, `permission denied`)
  and clear at the next key. Nothing is ever overwritten.
- While the prompt is open, keys go to it, not to the browser; the window's
  Cmd keys still work and cancel it.

### `a`: add

- The prompt reads `New: <folder>/` where the folder is, shown relative to the
  browser's root (the root itself shows as `./`):
  - the selected row, if it's a folder;
  - the selected file's folder, if it's a file;
  - the root, if the folder is empty.
- You type a name relative to that folder. `notes/today.md` creates `notes/`
  along the way; a trailing `/` makes a folder (`drafts/`).
- A new file is created empty and opens in nvim at once, as if chosen. A new
  folder is created and selected.

### `r`: rename

- The prompt reads `Rename: notes.md`, the current name, cursor at the end.
- The new name is relative to the item's folder. A `/` in it moves the item,
  but only somewhere inside the browser's root.
- An unchanged name does nothing.
- If the file is open in nvim, its buffer takes the new name and keeps any
  unsaved changes (the unsaved dot moves with it); `:w` afterwards writes to
  the new name without complaint. Renaming a folder does the same for every
  open file inside it.

### `d`: delete

- Asks, on the prompt row:
  - `Delete notes.md? (y/N)`
  - `Delete folder drafts/ and its 12 items? (y/N)` (items counted
    recursively; `1 item` singular)
  - When the file, or a file inside the folder, has unsaved changes in nvim:
    `notes.md has unsaved changes. Delete anyway? (y/N)` (for a folder:
    `drafts/ has unsaved changes. Delete anyway? (y/N)`)
- Only `y` deletes; any other key cancels.
- The item goes to the Trash. Buffers of deleted files are closed in nvim
  (unsaved changes discarded: the user confirmed).

## Constraints

- Pure logic in `ScwroteCore` with Swift Testing tests (prompt line editing,
  prompt states, path rules, action results). Disk work behind a small
  protocol so tests run on temporary folders and never touch the real Trash.
- nvim buffer sync uses the existing `NvimClient` and is tested against a
  real headless nvim (`HeadlessNvim`).
- Window keys stay Cmd-only. nvim never sees the browser's keys.
- README documents the keys.
