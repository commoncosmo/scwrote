import Testing
@testable import ScwroteCore

/// Physical keys (macOS virtual key codes, US layout positions).
private let key1: UInt16 = 18
private let leftBracket: UInt16 = 33
private let rightBracket: UInt16 = 30
private let keyF: UInt16 = 3
private let keyY: UInt16 = 16

/// A key as `NSEvent` reports it: the physical key and the character it types.
private func shortcut(_ keyCode: UInt16, _ characters: String?, _ modifiers: WindowShortcut.Modifiers) -> WindowShortcut? {
    WindowShortcut(keyCode: keyCode, characters: characters, modifiers: modifiers)
}

struct WindowShortcutTests {
    @Test func cmd1TogglesTheBrowserAndCmdShift1PinsIt() {
        #expect(shortcut(key1, "1", [.command]) == .toggleBrowser)
        #expect(shortcut(key1, "!", [.command, .shift]) == .toggleBrowserPin)
    }

    /// Digits go by the physical key: on AZERTY the 1 key types & unshifted.
    @Test func digitsMatchThePhysicalKeyInAnyLayout() {
        #expect(shortcut(key1, "&", [.command]) == .toggleBrowser)
        #expect(shortcut(key1, "1", [.command, .shift]) == .toggleBrowserPin)
    }

    @Test func cmdBracketsMoveOnePaneLeftOrRight() {
        #expect(shortcut(leftBracket, "[", [.command]) == .moveLeft)
        #expect(shortcut(rightBracket, "]", [.command]) == .moveRight)
    }

    @Test func cmd2TogglesThePreview() {
        #expect(shortcut(19, "2", [.command]) == .togglePreview)
        #expect(shortcut(19, "@", [.command, .shift]) == nil)
    }

    /// Cmd+{ and Cmd+} are left free.
    @Test func cmdShiftBracketsAreNotTaken() {
        #expect(shortcut(leftBracket, "{", [.command, .shift]) == nil)
        #expect(shortcut(rightBracket, "}", [.command, .shift]) == nil)
    }

    /// Without Cmd the keys belong to nvim: Ctrl-[ is Esc there.
    @Test func otherModifiersAreLeftForTheTerminal() {
        #expect(shortcut(leftBracket, "[", []) == nil)
        #expect(shortcut(leftBracket, "[", [.control]) == nil)
        #expect(shortcut(leftBracket, "“", [.option]) == nil)
        #expect(shortcut(leftBracket, "[", [.command, .option]) == nil)
        #expect(shortcut(keyF, "F", [.control, .shift]) == nil)
        #expect(shortcut(keyF, "F", [.command, .shift, .option]) == nil)
    }

    @Test func cmdShiftFSearchesTheFolder() {
        #expect(shortcut(keyF, "F", [.command, .shift]) == .search)
        #expect(shortcut(keyF, "f", [.command, .shift]) == .search)
        #expect(shortcut(keyF, "f", [.command]) == nil)
    }

    /// On Dvorak the physical F key types U and the physical Y key types F:
    /// search follows the F, and the U key stays with nvim.
    @Test func cmdShiftFFollowsTheTypedLetterOnDvorak() {
        #expect(shortcut(keyY, "F", [.command, .shift]) == .search)
        #expect(shortcut(keyF, "U", [.command, .shift]) == nil)
    }

    @Test func otherCmdKeysAreNotTaken() {
        #expect(shortcut(20, "3", [.command]) == nil) // Cmd+3
        #expect(shortcut(keyF, nil, [.command, .shift]) == nil)
    }
}
