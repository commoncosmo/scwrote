# File actions: open issues to revisit

Collected from the per-task and whole-branch reviews of the file actions
(branch `file-actions`), then worked through on 2026-11-10. Nothing here can
lose a file or act without a confirmation. File and line references will
drift.

## Check by hand

- [ ] Clicking into another pane while a prompt is open cancels it (the agents
  couldn't drive a click in the app; it shares the path that pane changes use,
  which was checked).
- [ ] Holding a key in the prompt, then closing it with a window shortcut
  (Cmd+1), sends no repeats into the browser. Covered by `PromptKeyRepeats`
  tests; the debug hooks can't hold one key across a shortcut.
- [ ] Deleting a symlink to a folder puts the link in the Trash, not the
  folder it points to. Not tried, so the real Trash stays untouched; the
  question already treats the link as a single item.

## Still open

- [ ] `renameBuffers`' leftover-buffer check (`nvim_buf_is_valid(other) and not
  nvim_buf_is_loaded(other)`) has no test: no hard-link setup made it matter
  (nvim refuses two buffers with one name, and opens hard links as one buffer).
  It stays as a guard against plugin autocommands.
- [ ] On volumes that can't rename exclusively (FAT, exFAT) or across volumes,
  a move checks and then acts, so a file appearing in between could in theory
  be replaced. Elsewhere the move is atomic.
- [ ] That a folder made by a failed create or move stays when something else
  put an item in it meanwhile is true by construction (`rmdir`), not tested.

## Done 2026-11-10

- Narrow browsers: a delete question drops `folder ` and then `Delete ` before
  giving up on the name, so `(y/N)` shows from 7 columns; the unsaved form keeps
  `has…` while the name shortens.
- Keys typed during `d`'s wait for nvim cancel the question and do nothing
  else (counts and `g` included); every window shortcut cancels it too.
- Any key repeat after the prompt opens or closes is dropped until a fresh
  key-down, whoever closed it.
- The prompt takes Home, End, Forward Delete, Ctrl-h and Cmd+V (first line
  only; a paste cancels a delete question).
- Moves are atomic (`renamex_np` with `RENAME_EXCL`), falling back to check
  then move across volumes and on FAT/exFAT.
- A stranded case-only rename names its hidden `.scwrote-rename-…` item.
- Cleanup after a failed create or move removes only the empty folders it made.
- `rename(file, to: "b/")` is refused: `a file name can't end in /`.
- The root is normalized; at `/` the add label is relative and the error reads
  `can't leave /`; `reveal` works there.
- A symlinked folder is asked about as one item (no count of its target).
- A symlinked folder's own row gets the unsaved dot; renaming a symlink selects
  the link, not its target.
- The file actions live in `EditorWindowController+FileActions.swift`.
- Typed or pasted combining marks no longer push the cursor past the text.
- Tests: the permission-denied mapping, nvim refusals asserting `.nvim`,
  mid-text Ctrl-w / Ctrl-u, nested and `/` add labels, Cmd+] setting
  `editorHasFile`.

## Decided against

- The delete question's item count includes hidden and `.git` items: they go
  to the Trash too.
- A symlink you made inside the folder is followed by `a`/`r`, so they can
  create or move things outside it (documented, pinned by a test).
- The browser's resolved-path cache clears only on reload: the folder watcher
  reloads on any change in the folder, a re-pointed link included.
