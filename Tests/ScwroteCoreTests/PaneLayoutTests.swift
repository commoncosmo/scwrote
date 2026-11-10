import Testing
@testable import ScwroteCore

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

struct PaneLayoutPreviewTests {
    @Test func cmd2ShowsGoesToThenHidesThePreview() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        #expect(layout.isPreviewShown && layout.focus == .preview)
        layout.clicked(.editor)
        layout.togglePreview()
        #expect(layout.isPreviewShown && layout.focus == .preview)
        layout.togglePreview()
        #expect(!layout.isPreviewShown && layout.focus == .editor)
    }

    /// In a window too narrow for it, a shown preview is squeezed out while
    /// the editor has the keyboard; Cmd+2 then hides it rather than going to it.
    @Test func cmd2OnASqueezedOutPreviewHidesIt() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        layout.leavePreview()
        layout.togglePreview(squeezedOut: true)
        #expect(!layout.isPreviewShown && layout.focus == .editor)
        layout.togglePreview(squeezedOut: false)
        #expect(layout.isPreviewShown && layout.focus == .preview)
    }

    @Test func bracketsMoveOnePaneAtATime() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()               // in the preview
        layout.moveLeft()
        #expect(layout.focus == .editor)
        layout.moveLeft()
        #expect(layout.focus == .browser && layout.mode == .split)
        layout.moveLeft()
        #expect(layout.focus == .browser)
        layout.moveRight()                    // unpinned browser hides on leaving
        #expect(layout.focus == .editor && layout.mode == .editorOnly)
        layout.moveRight()
        #expect(layout.focus == .preview)
        layout.moveRight()
        #expect(layout.focus == .preview)
    }

    @Test func moveRightFromTheEditorDoesNothingWithoutAPreview() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.moveRight()
        #expect(layout.focus == .editor && !layout.isPreviewShown)
    }

    @Test func leavingThePreviewKeepsItShown() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        layout.leavePreview()
        #expect(layout.focus == .editor && layout.isPreviewShown)
    }

    @Test func choosingAnImageShowsThePreviewAndStaysInTheBrowser() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.toggleBrowser()                // unpinned, focused
        layout.openedViewOnlyFile()
        #expect(layout.isPreviewShown && layout.focus == .browser && layout.mode == .split)
    }

    @Test func beforeAnyFileThePreviewSitsBesideTheFullBrowser() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.openedViewOnlyFile()
        #expect(layout.mode == .browserOnly && layout.isPreviewShown && layout.focus == .browser)
        layout.moveRight()
        #expect(layout.focus == .editor)
    }

    @Test func aPaneThatGivesWayHandsFocusToTheEditor() {
        var layout = PaneLayout(startsInBrowser: false)
        layout.togglePreview()
        layout.paneGaveWay(.preview)
        #expect(layout.focus == .editor && layout.isPreviewShown)
    }

    @Test func aPreviewThatGivesWayBeforeAnyFileHandsTheKeyboardToTheBrowser() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.togglePreview()
        layout.paneGaveWay(.preview)
        #expect(layout.focus == .browser && layout.isPreviewShown)
    }

    @Test func openingAFileKeepsThePreviewShown() {
        var layout = PaneLayout(startsInBrowser: true)
        layout.togglePreview()
        layout.openedFile()
        #expect(layout.isPreviewShown && layout.focus == .editor)
    }
}

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
