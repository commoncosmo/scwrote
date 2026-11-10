import Testing
@testable import ScwroteCore

/// Physical keys (macOS virtual key codes, US layout positions).
private let key1: UInt16 = 18
private let leftBracket: UInt16 = 33
private let rightBracket: UInt16 = 30

struct WindowShortcutTests {
    @Test func cmd1TogglesTheBrowserAndCmdShift1PinsIt() {
        #expect(WindowShortcut(keyCode: key1, modifiers: [.command]) == .toggleBrowser)
        #expect(WindowShortcut(keyCode: key1, modifiers: [.command, .shift]) == .toggleBrowserPin)
    }

    @Test func cmdBracketsMoveOnePaneLeftOrRight() {
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.command]) == .moveLeft)
        #expect(WindowShortcut(keyCode: rightBracket, modifiers: [.command]) == .moveRight)
    }

    @Test func cmd2TogglesThePreview() {
        #expect(WindowShortcut(keyCode: 19, modifiers: [.command]) == .togglePreview)
        #expect(WindowShortcut(keyCode: 19, modifiers: [.command, .shift]) == nil)
    }

    /// Cmd+{ and Cmd+} are left free.
    @Test func cmdShiftBracketsAreNotTaken() {
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.command, .shift]) == nil)
        #expect(WindowShortcut(keyCode: rightBracket, modifiers: [.command, .shift]) == nil)
    }

    /// Without Cmd the keys belong to nvim: Ctrl-[ is Esc there.
    @Test func otherModifiersAreLeftForTheTerminal() {
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: []) == nil)
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.control]) == nil)
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.option]) == nil)
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.command, .option]) == nil)
    }

    @Test func otherCmdKeysAreNotTaken() {
        #expect(WindowShortcut(keyCode: 20, modifiers: [.command]) == nil) // Cmd+3
    }
}
