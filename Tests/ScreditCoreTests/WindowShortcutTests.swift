import Testing
@testable import ScreditCore

/// Physical keys (macOS virtual key codes, US layout positions).
private let key1: UInt16 = 18
private let leftBracket: UInt16 = 33
private let rightBracket: UInt16 = 30

struct WindowShortcutTests {
    @Test func cmd1TogglesTheBrowserAndCmdShift1PinsIt() {
        #expect(WindowShortcut(keyCode: key1, modifiers: [.command]) == .toggleBrowser)
        #expect(WindowShortcut(keyCode: key1, modifiers: [.command, .shift]) == .toggleBrowserPin)
    }

    @Test func cmdBracketsGoToEachPane() {
        #expect(WindowShortcut(keyCode: leftBracket, modifiers: [.command]) == .goToBrowser)
        #expect(WindowShortcut(keyCode: rightBracket, modifiers: [.command]) == .goToEditor)
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
        #expect(WindowShortcut(keyCode: 19, modifiers: [.command]) == nil) // Cmd+2
    }
}
