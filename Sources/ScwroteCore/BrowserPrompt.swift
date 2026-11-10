import Foundation

/// A key the browser's one-line prompt understands.
public enum PromptKey: Equatable, Sendable {
    case character(Character), backspace, left, right, start, end, deleteWord, deleteToStart, enter, escape

    /// The browser's keys that mean something in the prompt; Ctrl-u
    /// (`halfPageUp`) is deleteToStart. Up, down and Ctrl-d mean nothing here.
    public init?(_ key: BrowserKey) {
        switch key {
        case .character(let c): self = .character(c)
        case .left: self = .left
        case .right: self = .right
        case .enter: self = .enter
        case .escape: self = .escape
        case .halfPageUp: self = .deleteToStart
        case .up, .down, .halfPageDown: return nil
        }
    }

    /// What a key typed, as a character for the line: one printable
    /// character. Tab, Delete and the like are control characters, and
    /// function keys (F1, Home, Page Up...) type private-use ones; none
    /// belongs in a file name.
    public init?(typed text: String) {
        guard text.count == 1, let character = text.first else { return nil }
        let printable = character.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
        guard printable else { return nil }
        self = .character(character)
    }
}

/// The text being typed in the prompt, with a cursor counted in Characters so
/// "ü" or an emoji is one step.
public struct PromptLine: Equatable, Sendable {
    public private(set) var text: String
    /// In Characters, 0...text.count.
    public private(set) var cursor: Int

    public init(_ text: String = "") {
        self.text = text
        cursor = text.count
    }

    /// Applies an editing key. Enter and Escape are the prompt's business, not
    /// the line's, so they change nothing.
    public mutating func edit(_ key: PromptKey) {
        switch key {
        case .character(let c):
            var chars = Array(text)
            chars.insert(c, at: cursor)
            text = String(chars)
            cursor += 1
        case .backspace:
            remove(from: cursor - 1)
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(text.count, cursor + 1)
        case .start: cursor = 0
        case .end: cursor = text.count
        case .deleteWord: remove(from: wordStart())
        case .deleteToStart: remove(from: 0)
        case .enter, .escape: break
        }
    }

    /// Removes the Characters from `start` up to the cursor.
    private mutating func remove(from start: Int) {
        guard start >= 0, start < cursor else { return }
        var chars = Array(text)
        chars.removeSubrange(start..<cursor)
        text = String(chars)
        cursor = start
    }

    /// Where vim's Ctrl-w would stop: skip separators (spaces, `/`) back from
    /// the cursor, then the run of other characters. `/` separates so one
    /// press removes one path part.
    private func wordStart() -> Int {
        let chars = Array(text)
        var i = cursor
        while i > 0, Self.isSeparator(chars[i - 1]) { i -= 1 }
        while i > 0, !Self.isSeparator(chars[i - 1]) { i -= 1 }
        return i
    }

    private static func isSeparator(_ c: Character) -> Bool { c == " " || c == "/" }
}

/// The browser's one-line prompt for add, rename and delete: what it asks, the
/// text typed so far, and what a key does. Pure state; the file work happens in
/// whoever reads the outcome.
public struct BrowserPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case add(folder: String)
        case rename(path: String)
        case delete(path: String, question: String)
    }

    public enum Outcome: Equatable, Sendable { case editing, cancelled, submitted(String), confirmed }

    public let kind: Kind
    public private(set) var line: PromptLine
    public private(set) var error: String?
    private let addLabel: String

    private init(kind: Kind, line: PromptLine, addLabel: String = "") {
        self.kind = kind
        self.line = line
        self.addLabel = addLabel
    }

    /// `folder` and `root` are absolute; the label shows the folder relative to
    /// the root, which itself reads as `./`.
    public static func add(folder: String, root: String) -> BrowserPrompt {
        var relative = folder
        if folder == root {
            relative = "."
        } else if folder.hasPrefix(root + "/") {
            relative = String(folder.dropFirst(root.count + 1))
        }
        return BrowserPrompt(kind: .add(folder: folder), line: PromptLine(), addLabel: "New: \(relative)/")
    }

    /// Starts with the current name so a small fix is a few keys.
    public static func rename(path: String) -> BrowserPrompt {
        BrowserPrompt(kind: .rename(path: path), line: PromptLine((path as NSString).lastPathComponent))
    }

    public static func delete(path: String, question: String) -> BrowserPrompt {
        BrowserPrompt(kind: .delete(path: path, question: question), line: PromptLine())
    }

    /// "New: notes/" ("New: ./" for the root), "Rename: ", or the question.
    public var label: String {
        switch kind {
        case .add: addLabel
        case .rename: "Rename: "
        case .delete(_, let question): question
        }
    }

    public mutating func handle(_ key: PromptKey) -> Outcome {
        error = nil
        if case .delete = kind {
            return key == .character("y") ? .confirmed : .cancelled
        }
        switch key {
        case .enter: return .submitted(line.text)
        case .escape: return .cancelled
        default:
            line.edit(key)
            return .editing
        }
    }

    /// A key with no meaning in the prompt (↑, Ctrl-d, a Cmd key that isn't
    /// the window's). It cancels a delete, since only `y` confirms one;
    /// anywhere else it only clears the error, like any key.
    public mutating func handleUnmapped() -> Outcome {
        error = nil
        if case .delete = kind { return .cancelled }
        return .editing
    }

    /// Shows `message` until the next key; the prompt stays open.
    public mutating func fail(_ message: String) {
        error = message
    }
}

/// Which key repeats the browser drops around its prompt. Held keys repeat
/// in the prompt as in vim's command line (Backspace, ← →), except:
///
/// - the key that opened or closed the prompt, until it's released or
///   another key goes down: holding `a` mustn't type "aaa" into the new
///   name, and holding Enter or Esc mustn't carry on into the browser;
/// - any key in a delete question, where a single key answers.
public struct PromptKeyRepeats: Equatable, Sendable {
    private var held: UInt16?

    public init() {}

    /// Whether to drop this key-down. A key that isn't dropped goes down
    /// after the held one, so it ends the hold.
    public mutating func drops(keyCode: UInt16, isRepeat: Bool, inDeleteQuestion: Bool) -> Bool {
        if isRepeat, keyCode == held || inDeleteQuestion { return true }
        held = nil
        return false
    }

    /// The key just opened or closed the prompt, or asked for one (`d`
    /// waits to hear from nvim first).
    public mutating func openedOrClosedPrompt(keyCode: UInt16) {
        held = keyCode
    }

    public mutating func released(keyCode: UInt16) {
        if keyCode == held { held = nil }
    }
}
