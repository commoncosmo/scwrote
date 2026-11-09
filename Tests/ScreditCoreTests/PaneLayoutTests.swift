import Testing
@testable import ScreditCore

struct PaneLayoutStartTests {
    @Test func startingOnAFolderShowsOnlyTheBrowser() {
        let layout = PaneLayout(startsInBrowser: true)

        #expect(layout.mode == .browserOnly)
        #expect(layout.focus == .browser)
    }

    @Test func startingOnAFileShowsOnlyTheEditor() {
        let layout = PaneLayout(startsInBrowser: false)

        #expect(layout.mode == .editorOnly)
        #expect(layout.focus == .editor)
    }
}

struct PaneLayoutToggleTests {
    /// Cmd+1, the way JetBrains' Project panel works: show it, go to it, hide it.
    @Test func toggleShowsThenHidesTheBrowser() {
        var layout = PaneLayout(startsInBrowser: false)

        layout.toggleBrowser()
        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)

        layout.toggleBrowser()
        #expect(layout.mode == .editorOnly)
        #expect(layout.focus == .editor)
    }

    @Test func toggleFromTheEditorMovesIntoAVisibleBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePin() // pinned: shown, focus stays in the editor
        #expect(layout.mode == .split)
        #expect(layout.focus == .editor)

        layout.toggleBrowser()

        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)
    }

    @Test func toggleDoesNothingBeforeAnyFileIsOpen() {
        var layout = PaneLayout(startsInBrowser: true)

        layout.toggleBrowser()

        #expect(layout.mode == .browserOnly)
        #expect(layout.focus == .browser)
    }
}

struct PaneLayoutOpenAndLeaveTests {
    @Test func openingAFileHidesAnUnpinnedBrowser() {
        var layout = PaneLayout(startsInBrowser: true)

        layout.openedFile()

        #expect(layout.mode == .editorOnly)
        #expect(layout.focus == .editor)
    }

    @Test func openingAFileKeepsAPinnedBrowserBesideTheEditor() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.togglePin()

        layout.openedFile()

        #expect(layout.mode == .split)
        #expect(layout.focus == .editor)
    }

    @Test func escapeReturnsToTheEditorAndHidesAnUnpinnedBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()

        layout.leaveBrowser()

        #expect(layout.mode == .editorOnly)
        #expect(layout.focus == .editor)
    }

    @Test func escapeKeepsAPinnedBrowserOpen() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()
        layout.togglePin()

        layout.leaveBrowser()

        #expect(layout.mode == .split)
        #expect(layout.focus == .editor)
    }

    @Test func escapeDoesNothingBeforeAnyFileIsOpen() {
        var layout = PaneLayout(startsInBrowser: true)

        layout.leaveBrowser()

        #expect(layout.mode == .browserOnly)
        #expect(layout.focus == .browser)
    }
}

struct PaneLayoutPinTests {
    @Test func pinningAHiddenBrowserShowsIt() {
        var layout = PaneLayout(startsInBrowser: false)

        layout.togglePin()

        #expect(layout.isPinned)
        #expect(layout.mode == .split)
    }

    @Test func unpinningFromTheEditorHidesTheBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePin()

        layout.togglePin()

        #expect(!layout.isPinned)
        #expect(layout.mode == .editorOnly)
    }

    @Test func unpinningWhileInTheBrowserLeavesItOpenUntilYouLeave() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()
        layout.togglePin()

        layout.togglePin()

        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)
    }

    @Test func clickingTheEditorHidesAnUnpinnedBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()

        layout.clicked(.editor)

        #expect(layout.mode == .editorOnly)
        #expect(layout.focus == .editor)
    }

    @Test func clickingBetweenPinnedPanesJustMovesFocus() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePin()

        layout.clicked(.browser)
        #expect(layout.focus == .browser)

        layout.clicked(.editor)
        #expect(layout.mode == .split)
        #expect(layout.focus == .editor)
    }
}

/// Cmd+[: go to the browser, wherever you are.
struct PaneLayoutFocusBrowserTests {
    @Test func aHiddenBrowserIsShownAndFocused() {
        var layout = PaneLayout(startsInBrowser: false)

        layout.focusBrowser()

        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)
    }

    @Test func aPinnedBrowserJustTakesFocus() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePin()

        layout.focusBrowser()

        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)
    }

    /// Unlike Cmd+1, asking again never hides it.
    @Test func askingFromInsideTheBrowserChangesNothing() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.focusBrowser()

        layout.focusBrowser()

        #expect(layout.mode == .split)
        #expect(layout.focus == .browser)
    }

    @Test func theFullWindowBrowserStaysFullWindow() {
        var layout = PaneLayout(startsInBrowser: true)

        layout.focusBrowser()

        #expect(layout.mode == .browserOnly)
        #expect(layout.focus == .browser)
    }
}
