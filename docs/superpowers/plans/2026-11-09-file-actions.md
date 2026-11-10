# File Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add/rename/delete files and folders from the file browser (`a`, `r`, `d` with a one-line prompt), keep nvim's buffers in step, and let an empty folder reach the editor.

**Architecture:** Pure rules in `ScwroteCore`: the prompt's line editing and states, path rules and disk actions behind a `FileSystem` protocol, and nvim buffer sync as `NvimClient` methods. The app's `FileBrowserView` draws the prompt and routes keys to it; `EditorWindowController` runs the actions, reloads the browser, opens new files, and syncs nvim.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, AppKit, nvim msgpack-RPC + Lua.

**Spec:** `docs/superpowers/specs/2026-11-09-file-actions-design.md`

## Global Constraints

- `ScwroteCore` stays free of AppKit and unit tested; new pure logic goes there.
- Tests never touch the real Trash: `LocalFileSystem(trashFolder:)` with a temp folder.
- Never overwrite: an existing destination is an error. Deletes go to the Trash.
- `a` and `r` never create or move anything outside the browser's root.
- Only `y` confirms a delete; any other key cancels.
- Window keys stay Cmd-only.
- Exact prompt and message text (from the spec): `New: <folder>/` (root shows as `./`), `Rename: `, `Delete notes.md? (y/N)`, `Delete folder drafts/ and its 12 items? (y/N)` (`1 item`), `notes.md has unsaved changes. Delete anyway? (y/N)`, `drafts/ has unsaved changes. Delete anyway? (y/N)`, `notes.md already exists`, `permission denied`, empty-folder row `(empty) · a: new file`.

## Review Focus

1. **Case-only rename** on case-insensitive APFS (`Notes.md` → `notes.md`) must succeed, not report "already exists". Pinned in Task 3 (`renameChangesOnlyTheCase`).
2. **Names that escape the root** (`../x`, `/etc/x`, `a/../../x`) are refused and create nothing. Pinned in Task 3 (`namesThatLeaveTheRootAreRefused`).
3. **Dotfiles, spaces and non-ASCII names** (`.env`, `my notes.md`, `über.md`) create and rename fine. Pinned in Task 3 (`unusualNamesWork`).
4. **The item vanished between `r`/`d` and Enter** (deleted outside scwrote) gives a message, not a crash. Pinned in Task 3 (`actingOnAMissingItemSaysSo`).
5. **A folder holding an unsaved open file** is described as unsaved in the delete question, and its buffers are closed after the delete. Pinned in Task 3 (`deleteQuestionForAFolderWithUnsavedFiles`) and Task 4 (`closingAFolderClosesTheBuffersInside`).

---

### Task 1: Reach the editor from an empty folder

**Files:**
- Modify: `Sources/ScwroteCore/PaneLayout.swift`, `Sources/Scwrote/FileBrowserView.swift` (the `(empty)` row)
- Test: `Tests/ScwroteCoreTests/PaneLayoutTests.swift`

**Interfaces:**
- Changes: `PaneLayout.leaveBrowser()` and `moveRight()` from the browser work without a file open: focus `.editor`, `mode` `.editorOnly` unless pinned (then `.split`), and `editorHasFile` becomes true from then on (the editor is in use: Cmd+1 can hide the browser afterwards).

- [ ] **Step 1: Write the failing tests** (in `PaneLayoutTests.swift`; update `beforeAnyFileThePreviewSitsBesideTheFullBrowser`, whose last assertions pinned the old no-op)

```swift
struct PaneLayoutEmptyFolderTests {
    @Test func escReachesTheEditorBeforeAnyFileIsOpen() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.leaveBrowser()
        #expect(layout.focus == .editor && layout.mode == .editorOnly && layout.editorHasFile)
    }

    @Test func cmdRightBracketDoesTheSame() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.moveRight()
        #expect(layout.focus == .editor && layout.mode == .editorOnly)
    }

    @Test func aPinnedBrowserStaysWhenLeftEarly() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.togglePin()
        layout.leaveBrowser()
        #expect(layout.focus == .editor && layout.mode == .split)
    }

    @Test func afterLeavingEarlyCmd1CanHideTheBrowser() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.leaveBrowser()
        layout.toggleBrowser()
        layout.toggleBrowser()
        #expect(layout.mode == .editorOnly && layout.focus == .editor)
    }
}
```
In `beforeAnyFileThePreviewSitsBesideTheFullBrowser`, replace the final `moveRight`/`leaveBrowser` no-op assertions with: after `moveRight()`, `focus == .editor`.

- [ ] **Step 2: Run, expect failure:** `swift test --filter PaneLayout`
- [ ] **Step 3: Implement** in `PaneLayout.swift`; in `FileBrowserView.draw`, the empty row text becomes `(empty) · a: new file`.
- [ ] **Step 4: Run, expect pass:** `swift test` (all)
- [ ] **Step 5: Commit:** `git commit -am "An empty folder can reach the editor: Esc and Cmd+] work before a file is open"`

---

### Task 2: The prompt (line editing and states)

**Files:**
- Create: `Sources/ScwroteCore/BrowserPrompt.swift`
- Test: `Tests/ScwroteCoreTests/BrowserPromptTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PromptKey: Equatable, Sendable {
      case character(Character), backspace, left, right, start, end, deleteWord, deleteToStart, enter, escape
      /// The browser's keys that mean something in the prompt; Ctrl-u (`halfPageUp`) is deleteToStart.
      public init?(_ key: BrowserKey)
  }
  public struct PromptLine: Equatable, Sendable {
      public private(set) var text: String
      public private(set) var cursor: Int          // in Characters, 0...text.count
      public init(_ text: String = "")             // cursor at the end
      public mutating func edit(_ key: PromptKey)  // enter/escape: no change
  }
  public struct BrowserPrompt: Equatable, Sendable {
      public enum Kind: Equatable, Sendable {
          case add(folder: String)                 // absolute folder path
          case rename(path: String)
          case delete(path: String, question: String)
      }
      public enum Outcome: Equatable, Sendable { case editing, cancelled, submitted(String), confirmed }
      public let kind: Kind
      public private(set) var line: PromptLine
      public private(set) var error: String?
      public static func add(folder: String, root: String) -> BrowserPrompt     // empty line
      public static func rename(path: String) -> BrowserPrompt                 // line = last path component
      public static func delete(path: String, question: String) -> BrowserPrompt
      /// "New: notes/" ("New: ./" for the root), "Rename: ", or the question.
      public var label: String
      public mutating func handle(_ key: PromptKey) -> Outcome
      /// Shows `message` until the next key; the prompt stays open.
      public mutating func fail(_ message: String)
  }
  ```

Rules: `deleteWord` removes the word before the cursor (vim's Ctrl-w: skip spaces/`/` back, then the non-separator run; `/` counts as a separator so `notes/today` + Ctrl-w → `notes/`). `deleteToStart` removes everything before the cursor. Add/rename: Enter → `.submitted(text)` (even empty: the actions report the error), Esc → `.cancelled`, anything else edits → `.editing`. Delete: `.character("y")` → `.confirmed`, every other key → `.cancelled`. Any key clears `error` before being handled. The `add` label's folder is relative to `root` with a trailing `/`.

- [ ] **Step 1: Write the failing tests**

```swift
struct PromptLineTests {
    private func line(_ text: String, _ keys: [PromptKey]) -> PromptLine {
        var line = PromptLine(text)
        for key in keys { line.edit(key) }
        return line
    }

    @Test func typesAtTheCursor() {
        let edited = line("ac", [.left, .character("b")])
        #expect(edited.text == "abc" && edited.cursor == 2)
    }

    @Test func backspaceAndMoves() {
        #expect(line("abc", [.backspace]).text == "ab")
        #expect(line("abc", [.start, .backspace]).text == "abc")
        #expect(line("abc", [.start, .right, .backspace]).text == "bc")
        #expect(line("abc", [.start, .end]).cursor == 3)
        #expect(line("abc", [.right]).cursor == 3)
    }

    @Test func ctrlWDeletesAWordOrAPathPart() {
        #expect(line("my notes", [.deleteWord]).text == "my ")
        #expect(line("notes/today", [.deleteWord]).text == "notes/")
        #expect(line("notes/", [.deleteWord]).text == "")
    }

    @Test func ctrlUDeletesBeforeTheCursor() {
        #expect(line("abcdef", [.left, .left, .deleteToStart]).text == "ef")
    }

    @Test func charactersCountAsOne() {
        #expect(line("über", [.backspace, .start, .right, .backspace]).text == "be")
    }
}

struct BrowserPromptTests {
    @Test func labels() {
        #expect(BrowserPrompt.add(folder: "/p/notes", root: "/p").label == "New: notes/")
        #expect(BrowserPrompt.add(folder: "/p", root: "/p").label == "New: ./")
        #expect(BrowserPrompt.rename(path: "/p/a.md").label == "Rename: ")
        #expect(BrowserPrompt.rename(path: "/p/a.md").line.text == "a.md")
        #expect(BrowserPrompt.delete(path: "/p/a.md", question: "Delete a.md? (y/N)").label == "Delete a.md? (y/N)")
    }

    @Test func enterSubmitsAndEscCancels() {
        var prompt = BrowserPrompt.add(folder: "/p", root: "/p")
        #expect(prompt.handle(.character("x")) == .editing)
        #expect(prompt.handle(.enter) == .submitted("x"))
        #expect(prompt.handle(.escape) == .cancelled)
    }

    @Test func onlyYConfirmsADelete() {
        var prompt = BrowserPrompt.delete(path: "/p/a.md", question: "?")
        #expect(prompt.handle(.character("y")) == .confirmed)
        for key: PromptKey in [.character("Y"), .character("n"), .enter, .escape, .backspace] {
            var other = BrowserPrompt.delete(path: "/p/a.md", question: "?")
            #expect(other.handle(key) == .cancelled)
        }
    }

    @Test func anErrorShowsUntilTheNextKey() {
        var prompt = BrowserPrompt.rename(path: "/p/a.md")
        prompt.fail("b.md already exists")
        #expect(prompt.error == "b.md already exists")
        _ = prompt.handle(.left)
        #expect(prompt.error == nil)
    }

    @Test func browserKeysMapToPromptKeys() {
        #expect(PromptKey(.character("a")) == .character("a"))
        #expect(PromptKey(.halfPageUp) == .deleteToStart)
        #expect(PromptKey(.enter) == .enter)
        #expect(PromptKey(.down) == nil)
        #expect(PromptKey(.halfPageDown) == nil)
    }
}
```

- [ ] **Step 2: Run, expect failure:** `swift test --filter "PromptLine|BrowserPrompt"`
- [ ] **Step 3: Implement** `BrowserPrompt.swift`.
- [ ] **Step 4: Run, expect pass:** `swift test`
- [ ] **Step 5: Commit:** `git add -A Sources/ScwroteCore Tests/ScwroteCoreTests && git commit -m "Browser prompt: one-line editing and add/rename/delete states"`

---

### Task 3: File actions and the file system

**Files:**
- Create: `Sources/ScwroteCore/FileActions.swift` (protocol, `LocalFileSystem`, `FileActions`)
- Test: `Tests/ScwroteCoreTests/FileActionsTests.swift`

**Interfaces:**
- Consumes: `FileEntry` (existing), `UnsavedFiles` (`paths`, `marks(_:isDirectory:)`).
- Produces:
  ```swift
  public protocol FileSystem: Sendable {
      func itemExists(at path: String) -> Bool
      func isFolder(at path: String) -> Bool
      /// Same item (e.g. a case-only rename on a case-insensitive volume).
      func isSameItem(_ a: String, _ b: String) -> Bool
      func createFile(at path: String) throws          // makes missing parent folders; fails if it exists
      func createFolder(at path: String) throws        // makes missing parents; fails if it exists
      func moveItem(at source: String, to destination: String) throws   // makes missing parents
      func trashItem(at path: String) throws
      func itemCount(inFolder path: String) -> Int     // everything inside, recursively
  }
  public struct LocalFileSystem: FileSystem {
      /// nil: the user's Trash. Tests pass a temp folder.
      public init(trashFolder: String? = nil)
  }
  public struct FileActionError: Error, Equatable, Sendable { public let message: String }
  public struct NewItem: Equatable, Sendable { public let path: String; public let isFolder: Bool }
  public struct FileActions: Sendable {
      public init(root: String, fileSystem: any FileSystem)
      /// Where `a` puts a new item: the selected folder, the selected file's folder, or the root.
      public func folderForNewItem(selected: FileEntry?) -> String
      public func create(_ name: String, in folder: String) -> Result<NewItem, FileActionError>
      /// The new path, or nil when the name didn't change.
      public func rename(_ path: String, to name: String) -> Result<String?, FileActionError>
      /// `hasUnsavedChanges`: the item, or anything inside it, has unsaved changes in nvim.
      public func deleteQuestion(for path: String, hasUnsavedChanges: Bool) -> String
      public func delete(_ path: String) -> Result<Void, FileActionError>
  }
  ```

Rules:
- Names are relative to the folder (`create`) or the item's folder (`rename`). Resolve `.`/`..` components; the result must be inside `root` (not the root itself), else `FileActionError("can't leave <root's last component>/")`. A leading `/` is refused the same way. Empty (or only `/`) → `"name can't be empty"`.
- `create`: trailing `/` → folder. Existing → `"<name as typed, without trailing slash> already exists"`.
- `rename`: unchanged resolved path → `.success(nil)`. Destination exists and isn't the same item → `"<name> already exists"`. Source missing → `"<last component> no longer exists"`. Case-only rename on a case-insensitive volume must work (move via a temporary name if `moveItem` refuses).
- `delete`: missing → `"<last component> no longer exists"`. Uses `trashItem`.
- Errors from the file system map to `"permission denied"` for permission errors (`CocoaError.fileWriteNoPermission`, `.fileReadNoPermission`, POSIX `EACCES`/`EPERM`), else the error's `localizedDescription`.
- Questions: file → `Delete notes.md? (y/N)`; folder → `Delete folder drafts/ and its 12 items? (y/N)` (`1 item`, `0 items`); unsaved → `notes.md has unsaved changes. Delete anyway? (y/N)` / `drafts/ has unsaved changes. Delete anyway? (y/N)`.

- [ ] **Step 1: Write the failing tests** — a `TempFolder` helper (creates a uniquely named temp dir with a `trash` sibling, `LocalFileSystem(trashFolder:)`, removes both on deinit). Tests (names and assertions):
  - `folderForNewItemFollowsTheSelection`: folder entry → its path; file entry `/r/notes/a.md` → `/r/notes`; nil → root.
  - `createsAFileAndItsFolders`: `create("notes/today.md", in: root)` → `.success(NewItem(path: root+"/notes/today.md", isFolder: false))`, file exists and is empty.
  - `aTrailingSlashMakesAFolder`: `create("drafts/", in: root)` → folder exists, `isFolder == true`.
  - `existingNamesAreRefused`: second `create("a.md")` → `.failure(FileActionError(message: "a.md already exists"))`, content untouched.
  - `emptyNamesAreRefused`: `""` and `"/"` → `"name can't be empty"`.
  - `namesThatLeaveTheRootAreRefused`: `"../x"`, `"/etc/x"`, `"a/../../x"` → failure with message starting `"can't leave "`, nothing created outside.
  - `unusualNamesWork`: `.env`, `my notes.md`, `über.md` create; renaming `my notes.md` → `über 2.md` works.
  - `renameMovesWithinTheRoot`: `rename(root+"/a.md", to: "sub/b.md")` → `.success(root+"/sub/b.md")`, old gone.
  - `renameToTheSameNameDoesNothing`: → `.success(nil)`.
  - `renameChangesOnlyTheCase`: `Notes.md` → `notes.md` succeeds and the directory listing shows `notes.md`.
  - `renameOntoAnExistingNameIsRefused`.
  - `actingOnAMissingItemSaysSo`: rename and delete of a removed file → `"a.md no longer exists"`.
  - `deleteGoesToTheTrash`: file and folder land in the temp trash folder, gone from root.
  - `deleteQuestions`: file, folder with 12 items, folder with 1 item, unsaved file, `deleteQuestionForAFolderWithUnsavedFiles` → exact strings above.
- [ ] **Step 2: Run, expect failure:** `swift test --filter FileActions`
- [ ] **Step 3: Implement** `FileActions.swift` (`LocalFileSystem` uses `FileManager`; `trashItem` uses `FileManager.trashItem` when `trashFolder` is nil, else moves into it under a unique name; `isSameItem` compares `.fileResourceIdentifierKey`).
- [ ] **Step 4: Run, expect pass:** `swift test`
- [ ] **Step 5: Commit:** `git commit -m "File actions: create, rename and delete with path rules, behind a file system protocol"` (after `git add`)

---

### Task 4: Keep nvim's buffers in step

**Files:**
- Create: `Sources/ScwroteCore/NvimClient+Files.swift`
- Test: `Tests/ScwroteCoreTests/NvimFileSyncTests.swift` (uses `HeadlessNvim`)

**Interfaces:**
- Produces:
  ```swift
  extension NvimClient {
      /// After the file or folder at `from` moved to `to` on disk: every loaded buffer at `from`
      /// or under it takes the matching name under `to`, keeping unsaved changes, and `:w`
      /// afterwards writes to the new name without an error. No buffer keeps the old name.
      public func renameBuffers(from: String, to: String) throws
      /// Closes every buffer at `path` or under it, discarding unsaved changes.
      public func closeBuffers(at path: String) throws
  }
  ```
  Paths in nvim's form (symlinks resolved). Pass them as Lua arguments, never spliced into commands. Note: `:file {name}` marks the buffer not-edited, so a plain `:w` refuses with E13 when the new file exists, and it leaves the old name behind as an alternate buffer. The implementation must avoid both, without writing the buffer's unsaved changes.

- [ ] **Step 1: Write the failing tests** (`@Suite(.enabled(if: nvimPath != nil))`):
  - `renamingAnOpenFileKeepsItsChanges`: edit `a.md`, make it modified (`ox<Esc>`), move `a.md` → `b.md` on disk, `renameBuffers(from: real(a), to: real(b))` → current buffer name `real(b)`, `&modified` true; then `:w` (via `nvim_exec2`, no error) → `b.md` on disk contains the edit; no buffer named `real(a)` in `nvim_list_bufs()`.
  - `renamingAFolderRenamesTheFilesInside`: two files under `d/` loaded (one hidden, `set hidden`), move `d` → `e`, `renameBuffers` → both names under `e/`.
  - `unrelatedBuffersAreLeftAlone`: `d2/x.md` loaded, rename `d` → `e` → `d2/x.md` unchanged.
  - `closingAFileDiscardsItsBuffer`: modified buffer for `a.md`, `closeBuffers(at: real(a))` → no buffer named it, no error.
  - `closingAFolderClosesTheBuffersInside`: two buffers under `d/`, one modified → both gone.
- [ ] **Step 2: Run, expect failure:** `swift test --filter NvimFileSync`
- [ ] **Step 3: Implement** with `nvim_exec_lua`.
- [ ] **Step 4: Run, expect pass:** `swift test` (and `--filter NvimFileSync` 3× for flakiness)
- [ ] **Step 5: Commit:** `git commit -m "nvim follows renames and deletes from the browser"` (after `git add`)

---

### Task 5: Wire the keys, the prompt and the actions into the window

**Files:**
- Modify: `Sources/ScwroteCore/FileBrowser.swift` (keys `a`, `r`, `d`), `Sources/Scwrote/FileBrowserView.swift` (prompt drawing and keys), `Sources/Scwrote/EditorWindowController.swift` (running actions), `Sources/Scwrote/DebugHooks.swift` (`<BS>`, `<C-a>`, `<C-e>`, `<C-w>`), `README.md`
- Test: `Tests/ScwroteCoreTests/FileBrowserTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- `BrowserAction` gains `.add`, `.rename(String)`, `.delete(String)`. In `FileBrowser.handle`: `a` → `.add`; `r` → `.rename(selectedPath)` and `d` → `.delete(selectedPath)` when there's a selection, else nil. Counts before them are ignored.
- `FileBrowserView`: `var prompt: BrowserPrompt? { didSet { needsDisplay = true } }`; `var onPrompt: ((BrowserPrompt.Outcome) -> Void)?`. While `prompt != nil`, `keyDown` and `press(_:)` send keys to the prompt (NSEvent → `PromptKey`: keyCode 51 → backspace, arrows, Enter, Esc, Ctrl-a/e/w/u, single characters; `press` maps `BrowserKey` via `PromptKey.init?`), then call `onPrompt` with the outcome when it isn't `.editing`. The prompt draws on the bottom row of the browser: label in `dim`, text in `foreground`, a block cursor (selection color behind the character at `line.cursor`, or a space at the end), and an error in `warning` in place of the text.
- `EditorWindowController`: holds `FileActions(root:fileSystem: LocalFileSystem())`, rebuilt when the browser's root changes. On `.add`/`.rename`/`.delete`, opens the matching prompt (delete's question uses `deleteQuestion(for:hasUnsavedChanges:)` with `browserView.unsaved.marks(nvimPath, isDirectory:)`). On the outcome: run the action; failure → `prompt.fail(message)`; success → close the prompt, `browserView.reload()`, reveal the new path, then:
  - created file → `choose(path)` (opens it in nvim as if chosen); created folder → selected;
  - renamed → `nvim.renameBuffers(from:to:)` with both paths in nvim's form (`FileBrowser.realPath`), on `nvimQueue`;
  - deleted → `nvim.closeBuffers(at:)` likewise.
  Any window shortcut, a click outside the browser, or focus leaving the browser cancels the prompt.
- README: add `a`, `r`, `d` to the browser key table, a short paragraph on the prompt (editing keys, Trash, nvim following renames), and the empty-folder note.

- [ ] **Step 1: Write the failing tests** in `FileBrowserTests.swift`: `aAsksToAdd` (`.add`), `rAndDActOnTheSelection` (`.rename(path)`, `.delete(path)`), `rAndDDoNothingInAnEmptyFolder` (nil).
- [ ] **Step 2: Run, expect failure:** `swift test --filter FileBrowser`
- [ ] **Step 3: Implement** the four app files and the README.
- [ ] **Step 4: Run:** `cd web && bun run build && cd .. && swift build && swift test` (all pass, no warnings).
- [ ] **Step 5: Verify in the app** (`swift build -c release`; fixtures under `/private/tmp/claude-501/scwrote-file-actions/`, never in the repo; view snapshots with Read):
  - empty folder: `SCWROTE_DEBUG_KEYS='a' SCWROTE_DEBUG_SNAPSHOT=…` shows `New: ./` on the bottom row; then `anotes/today.md<CR>` creates the file and nvim shows `today.md`;
  - `<Esc>` from an empty folder lands in nvim (snapshot shows the editor);
  - `r` on a file, `<C-w>`, type a new name, `<CR>`: renamed on disk and in nvim's status line;
  - `d` then `n`: nothing deleted; `d` then `y`: file gone from the folder, present in `~/.Trash` (use a uniquely named fixture file and remove it from the Trash afterwards);
  - `a` with an existing name shows `… already exists` on the bottom row.
- [ ] **Step 6: Commit:** `git commit -am "File browser: a adds, r renames, d deletes, with a one-line prompt"` (after `git add` of any new files)
