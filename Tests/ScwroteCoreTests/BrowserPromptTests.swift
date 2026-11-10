import Testing
@testable import ScwroteCore

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

    /// A combining accent joins the letter before it: one Character, so the
    /// cursor mustn't count two (the next key would index past the end).
    @Test func aCharacterThatMergesWithTheOneBeforeKeepsTheCursorInTheText() {
        let typed = line("e", [.character("\u{301}"), .character("x")])
        #expect(typed.text == "e\u{301}x" && typed.cursor == 2)

        var pasted = PromptLine("e")
        pasted.insert("\u{301}\u{301}")
        pasted.edit(.backspace)
        #expect(pasted.text.isEmpty && pasted.cursor == 0)
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

    @Test func deleteForwardRemovesTheCharacterUnderTheCursor() {
        #expect(line("abc", [.start, .right, .deleteForward]).text == "ac")
        let mid = line("abc", [.start, .right, .deleteForward])
        #expect(mid.cursor == 1)
        let atEnd = line("abc", [.deleteForward])
        #expect(atEnd.text == "abc" && atEnd.cursor == 3)
        #expect(line("abc", [.start, .deleteForward]).text == "bc")
    }

    @Test func insertTypesEachPrintableCharacterAtTheCursor() {
        var edited = PromptLine("ac")
        edited.edit(.left)
        edited.insert("xyz")
        #expect(edited.text == "axyzc" && edited.cursor == 4)
    }

    @Test func insertStopsAtTheFirstNewlineAndDropsControls() {
        var edited = PromptLine("")
        edited.insert("one\ntwo")
        #expect(edited.text == "one")
        var tabbed = PromptLine("")
        tabbed.insert("a\tb\u{F704}c\r\nd")
        #expect(tabbed.text == "abc")
        var crlf = PromptLine("x")
        crlf.insert("\r\nignored")
        #expect(crlf.text == "x")
    }

    @Test func ctrlWInTheMiddleDeletesTheWordBeforeTheCursor() {
        // notes/today| .md with the cursor after "today"
        let moved = Array(repeating: PromptKey.left, count: 3)
        #expect(line("notes/today.md", moved + [.deleteWord]).text == "notes/.md")
        // Cursor right after the slash: one press removes the path part before it.
        let afterSlash = Array(repeating: PromptKey.left, count: 8)
        #expect(line("notes/today.md", afterSlash + [.deleteWord]).text == "today.md")
    }

    @Test func ctrlUInTheMiddleDeletesEverythingBeforeTheCursor() {
        let moved = Array(repeating: PromptKey.left, count: 3)
        let edited = line("notes/today.md", moved + [.deleteToStart])
        #expect(edited.text == ".md" && edited.cursor == 0)
    }

    @Test func charactersCountAsOne() {
        #expect(line("über", [.backspace, .start, .right, .backspace]).text == "be")
    }
}

private let deleteA = DeleteQuestion(before: "Delete ", name: "a.md", after: "?")

struct BrowserPromptTests {
    @Test func labels() {
        #expect(BrowserPrompt.add(folder: "/p/notes", root: "/p").label == "New: notes/")
        #expect(BrowserPrompt.add(folder: "/p", root: "/p").label == "New: ./")
        #expect(BrowserPrompt.rename(path: "/p/a.md").label == "Rename: ")
        #expect(BrowserPrompt.rename(path: "/p/a.md").line.text == "a.md")
        #expect(BrowserPrompt.delete(path: "/p/a.md", question: deleteA).label == "Delete a.md? (y/N)")
    }

    @Test func labelsAtARootOfSlash() {
        #expect(BrowserPrompt.add(folder: "/notes", root: "/").label == "New: notes/")
        #expect(BrowserPrompt.add(folder: "/", root: "/").label == "New: ./")
        #expect(BrowserPrompt.add(folder: "/p/notes/today", root: "/p").label == "New: notes/today/")
        #expect(BrowserPrompt.add(folder: "/notes/today", root: "/").label == "New: notes/today/")
    }

    @Test func pastingInsertsAndClearsTheError() {
        var prompt = BrowserPrompt.add(folder: "/p", root: "/p")
        prompt.fail("nope")
        #expect(prompt.paste("a/b\nc") == .editing)
        #expect(prompt.line.text == "a/b" && prompt.error == nil)
    }

    @Test func pastingCancelsADeleteQuestion() {
        var prompt = BrowserPrompt.delete(path: "/p/a.md", question: deleteA)
        #expect(prompt.paste("y") == .cancelled)
    }

    @Test func enterSubmitsAndEscCancels() {
        var prompt = BrowserPrompt.add(folder: "/p", root: "/p")
        #expect(prompt.handle(.character("x")) == .editing)
        #expect(prompt.handle(.enter) == .submitted("x"))
        #expect(prompt.handle(.escape) == .cancelled)
    }

    @Test func onlyYConfirmsADelete() {
        var prompt = BrowserPrompt.delete(path: "/p/a.md", question: deleteA)
        #expect(prompt.handle(.character("y")) == .confirmed)
        for key: PromptKey in [.character("Y"), .character("n"), .enter, .escape, .backspace] {
            var other = BrowserPrompt.delete(path: "/p/a.md", question: deleteA)
            #expect(other.handle(key) == .cancelled)
        }
    }

    /// An error replaces the label as well as the text, after a short word
    /// saying what failed, so a long label can never push it off the row.
    @Test func errorsFollowAShortLabel() {
        #expect(BrowserPrompt.add(folder: "/p/a/very/deep/folder", root: "/p").errorLabel == "New: ")
        #expect(BrowserPrompt.rename(path: "/p/a.md").errorLabel == "Rename: ")
        #expect(BrowserPrompt.delete(path: "/p/a.md", question: deleteA).errorLabel == "Delete: ")
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

    @Test func typedTextIsACharacterOnlyWhenPrintable() {
        #expect(PromptKey(typed: "a") == .character("a"))
        #expect(PromptKey(typed: "é") == .character("é"))
        #expect(PromptKey(typed: " ") == .character(" "))
        #expect(PromptKey(typed: "\t") == nil)
        #expect(PromptKey(typed: "\u{7f}") == nil)
        // Function keys (F1, Home, Page Up...) type private-use characters.
        #expect(PromptKey(typed: "\u{F704}") == nil)
        #expect(PromptKey(typed: "ab") == nil)
        #expect(PromptKey(typed: "") == nil)
    }
}

struct BrowserPromptUnmappedKeyTests {
    @Test func cancelsADelete() {
        var prompt = BrowserPrompt.delete(path: "/p/a.md", question: deleteA)
        #expect(prompt.handleUnmapped() == .cancelled)
    }

    @Test func onlyClearsTheErrorElsewhere() {
        var prompt = BrowserPrompt.rename(path: "/p/a.md")
        prompt.fail("b.md already exists")

        #expect(prompt.handleUnmapped() == .editing)
        #expect(prompt.error == nil)
        #expect(prompt.line.text == "a.md")
    }
}

/// Holding a key down: its repeats edit the prompt like vim's command line,
/// except after the prompt opened or closed (until a fresh key goes down:
/// holding `a` mustn't type "aaa" into the name, holding Enter or a window
/// shortcut mustn't carry on into the browser) and anything in a delete
/// question, where one key answers.
struct PromptKeyRepeatsTests {
    @Test func repeatsAfterThePromptOpenedAreDropped() {
        var repeats = PromptKeyRepeats()
        let pressed = repeats.drops(isRepeat: false, inDeleteQuestion: false)
        repeats.promptOpenedOrClosed()
        let repeated = repeats.drops(isRepeat: true, inDeleteQuestion: false)
        let again = repeats.drops(isRepeat: true, inDeleteQuestion: false)
        #expect(!pressed)
        #expect(repeated)
        #expect(again)
    }

    @Test func aFreshKeyDownEndsTheHoldSoOtherKeysRepeat() {
        var repeats = PromptKeyRepeats()
        repeats.promptOpenedOrClosed()
        let backspaceDown = repeats.drops(isRepeat: false, inDeleteQuestion: false)
        let backspaceRepeat = repeats.drops(isRepeat: true, inDeleteQuestion: false)
        #expect(!backspaceDown)
        #expect(!backspaceRepeat)
    }

    @Test func aNewHoldStartsWhenThePromptClosesAgain() {
        var repeats = PromptKeyRepeats()
        repeats.promptOpenedOrClosed()
        _ = repeats.drops(isRepeat: false, inDeleteQuestion: false)
        repeats.promptOpenedOrClosed()
        let repeated = repeats.drops(isRepeat: true, inDeleteQuestion: false)
        #expect(repeated)
    }

    @Test func everyRepeatInADeleteQuestionIsDropped() {
        var repeats = PromptKeyRepeats()
        let down = repeats.drops(isRepeat: false, inDeleteQuestion: true)
        let repeated = repeats.drops(isRepeat: true, inDeleteQuestion: true)
        #expect(!down)
        #expect(repeated)
    }

    @Test func nothingIsHeldAtFirst() {
        var repeats = PromptKeyRepeats()
        let repeated = repeats.drops(isRepeat: true, inDeleteQuestion: false)
        #expect(!repeated)
    }
}

/// A delete question in a row too narrow for it (the browser beside the
/// editor is about 33 columns): it keeps saying which item, and how to
/// answer. Measured in Characters here; the browser measures in points.
struct DeleteQuestionFittingTests {
    private let count = { (text: String) in Double(text.count) }
    private let longName = "chapter-03-the-long-night.md"

    @Test func aQuestionThatFitsIsWhole() {
        #expect(deleteA.fitted(to: 33, measure: count) == "Delete a.md? (y/N)")
    }

    @Test func aLongNameLosesItsMiddle() {
        let question = DeleteQuestion(before: "Delete ", name: longName, after: "?")
        #expect(question.fitted(to: 33, measure: count) == "Delete chapter-0…-night.md? (y/N)")
    }

    @Test func unsavedChangesStayInViewWithTheStartOfTheName() {
        let question = DeleteQuestion(before: "", name: longName, after: " has unsaved changes. Delete anyway?")
        #expect(question.fitted(to: 33, measure: count) == "chapter…ght.md has unsaved… (y/N)")
        let short = DeleteQuestion(before: "", name: "notes.md", after: " has unsaved changes. Delete anyway?")
        #expect(short.fitted(to: 33, measure: count) == "notes.md has unsaved… (y/N)")
    }

    @Test func aFolderKeepsItsNameOverItsCount() {
        let question = DeleteQuestion(before: "Delete folder ", name: "node_modules/", after: " and its 10,000+ items?")
        #expect(question.fitted(to: 33, measure: count) == "Delete folder node_modules/ (y/N)")
        #expect(question.fitted(to: 45, measure: count) == "Delete folder node_modules/ and its… (y/N)")
    }

    @Test func aFolderQuestionLosesItsWordsBeforeItsName() {
        let question = DeleteQuestion(before: "Delete folder ", name: "drafts/", after: " and its 12 items?")
        #expect(question.fitted(to: 22, measure: count) == "Delete drafts/ (y/N)")
        #expect(question.fitted(to: 20, measure: count) == "Delete drafts/ (y/N)")
        #expect(question.fitted(to: 19, measure: count) == "drafts/ (y/N)")
        #expect(question.fitted(to: 13, measure: count) == "drafts/ (y/N)")
        #expect(question.fitted(to: 12, measure: count) == "dra…s/ (y/N)")
        #expect(question.fitted(to: 7, measure: count) == "… (y/N)")
    }

    @Test func theUnsavedWarningOutlastsTheNameDownTo24Columns() {
        let question = DeleteQuestion(before: "", name: longName, after: " has unsaved changes. Delete anyway?")
        let fitted = question.fitted(to: 24, measure: count)
        #expect(fitted.hasSuffix(" has… (y/N)"), "\(fitted)")
        #expect(fitted == "chapte…ght.md has… (y/N)")
    }

    @Test func theAnswerAlwaysShows() {
        let questions = [
            DeleteQuestion(before: "Delete folder ", name: "a-folder-with-a-long-name/", after: " and its 12 items?"),
            DeleteQuestion(before: "", name: longName, after: " has unsaved changes. Delete anyway?"),
            DeleteQuestion(before: "Delete ", name: longName, after: "?"),
            DeleteQuestion(before: "Delete folder ", name: "drafts/", after: " and its 12 items?"),
        ]
        for question in questions {
            // "… (y/N)" is 7 columns: the least that says anything.
            for width in 6...80 {
                let fitted = question.fitted(to: Double(width), measure: count)
                guard width >= 7 else { continue }
                #expect(fitted.count <= width, "\(fitted) at \(width)")
                #expect(fitted.hasSuffix(" (y/N)"), "\(fitted) at \(width)")
            }
        }
    }
}
