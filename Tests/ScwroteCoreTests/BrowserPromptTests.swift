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
}
