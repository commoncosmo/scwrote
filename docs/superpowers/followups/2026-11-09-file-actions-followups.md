# File actions: open issues to revisit

Collected from the per-task and whole-branch reviews of the file actions
(branch `file-actions`, through bf6f95e). Nothing here can lose a file or act
without a confirmation; these are edges, polish and test gaps. File and line
references will drift.

## Check by hand

- [ ] Clicking into another pane while a prompt is open cancels it (the agents
  couldn't drive a click in the app; it shares the path that pane changes use,
  which was checked).

## Narrow browsers

- [ ] At very narrow widths (under ~21 columns: the minimum browser width, or a
  large Ghostty font) a folder's delete question can't fit and `(y/N)` is
  clipped; at 21–23 columns the name shrinks to `…`. Drop `folder ` or
  `Delete ` before giving up on the name (`DeleteQuestion.fitted`). The sweep
  test only covers widths 21–80.
- [ ] A long-named unsaved question drops `has unsaved changes` before it
  shortens the name, so at ~24 columns the warning isn't visible. Keep `has…`
  with a shorter name.

## Prompt and keys

- [ ] Keys typed during `d`'s short wait for nvim (up to 1 s) don't cancel the
  question that follows: `d` then `n` still opens it. Only a question can
  result, never an action.
- [ ] A digit or `g` typed during that wait stays as the browser's count or
  pending `g` until after the question closes.
- [ ] Holding a key while a window shortcut closes the prompt lets its repeats
  reach the browser.
- [ ] The prompt has no paste, Home/End, Forward-Delete or Ctrl-h (not in the
  spec's key list; they're ignored safely).

## Disk actions (`FileActions.swift`)

- [ ] `createFolder` and `moveItem` check, then act: a file appearing in
  between could in theory be replaced by a move (`renamex_np` with
  `RENAME_EXCL` would make it atomic).
- [ ] If a case-only rename's rollback also fails, the item stays under a
  hidden `.scwrote-rename-…` name; name it in the error message.
- [ ] Removing parent folders a failed create/move made is recursive, not
  empty-only (tiny race).
- [ ] `rename(file, to: "b/")` silently drops the slash.
- [ ] A root containing `.`/`..` or a trailing slash isn't normalized (fails
  closed: everything is refused). At `/` the add label is absolute and the
  escape error reads `can't leave //`.
- [ ] The item count includes hidden and `.git` items (arguably right: they go
  to the Trash too).
- [ ] For a symlinked folder the question counts the target's items, though
  only the link is trashed (overstates, the safe direction).
- [ ] A symlink you made inside the folder is followed by `a`/`r`, so they can
  create or move things outside it (accepted, documented, pinned by a test).

## Browser

- [ ] A symlinked folder's own row gets no unsaved dot (rows inside it do).
- [ ] After renaming a symlink to a file, the cursor lands on the target, not
  the link.
- [ ] The view's resolved-path cache only clears on reload.
- [ ] The file-actions part of `EditorWindowController` (~100 lines) could be
  its own extension file.

## Test gaps

- [ ] No stub test for the "permission denied" mapping.
- [ ] The nvim failure test asserts `Failure.self`, not `.nvim`.
- [ ] The leftover-buffer validity check (hard links) is untested.
- [ ] Prompt: mid-text Ctrl-w / Ctrl-u, nested folder labels, `cmdRightBracket`
  setting `editorHasFile`.
