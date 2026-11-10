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
        var prompt = BrowserPrompt.delete(path: "/p/a.md", question: "Delete a.md? (y/N)")
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
/// except the key that opened or closed the prompt (holding `a` mustn't type
/// "aaa" into the name, holding Enter mustn't carry on into the browser) and
/// anything in a delete question, where one key answers.
struct PromptKeyRepeatsTests {
    let a: UInt16 = 0, backspace: UInt16 = 51, left: UInt16 = 123

    @Test func repeatsOfTheKeyThatOpenedThePromptAreDropped() {
        var repeats = PromptKeyRepeats()
        let pressed = repeats.drops(keyCode: a, isRepeat: false, inDeleteQuestion: false)
        repeats.openedOrClosedPrompt(keyCode: a)
        let repeated = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        let again = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        #expect(!pressed)
        #expect(repeated)
        #expect(again)
    }

    @Test func otherKeysRepeatInThePrompt() {
        var repeats = PromptKeyRepeats()
        repeats.openedOrClosedPrompt(keyCode: a)
        let backspaceDown = repeats.drops(keyCode: backspace, isRepeat: false, inDeleteQuestion: false)
        let backspaceRepeat = repeats.drops(keyCode: backspace, isRepeat: true, inDeleteQuestion: false)
        let leftRepeat = repeats.drops(keyCode: left, isRepeat: true, inDeleteQuestion: false)
        #expect(!backspaceDown)
        #expect(!backspaceRepeat)
        #expect(!leftRepeat)
    }

    @Test func releasingTheKeyEndsTheHold() {
        var repeats = PromptKeyRepeats()
        repeats.openedOrClosedPrompt(keyCode: a)
        repeats.released(keyCode: backspace)
        let stillHeld = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        repeats.released(keyCode: a)
        let pressedAgain = repeats.drops(keyCode: a, isRepeat: false, inDeleteQuestion: false)
        let repeatedAgain = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        #expect(stillHeld)
        #expect(!pressedAgain)
        #expect(!repeatedAgain)
    }

    @Test func anotherKeyGoingDownEndsTheHold() {
        var repeats = PromptKeyRepeats()
        repeats.openedOrClosedPrompt(keyCode: a)
        _ = repeats.drops(keyCode: backspace, isRepeat: false, inDeleteQuestion: false)
        let repeated = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        #expect(!repeated)
    }

    @Test func everyRepeatInADeleteQuestionIsDropped() {
        var repeats = PromptKeyRepeats()
        let down = repeats.drops(keyCode: left, isRepeat: false, inDeleteQuestion: true)
        let repeated = repeats.drops(keyCode: left, isRepeat: true, inDeleteQuestion: true)
        #expect(!down)
        #expect(repeated)
    }

    @Test func nothingIsHeldAtFirst() {
        var repeats = PromptKeyRepeats()
        let repeated = repeats.drops(keyCode: a, isRepeat: true, inDeleteQuestion: false)
        #expect(!repeated)
    }
}
