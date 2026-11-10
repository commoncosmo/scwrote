import Foundation

/// A key the browser's one-line prompt understands.
public enum PromptKey: Equatable, Sendable {
    case character(Character), backspace, deleteForward, left, right, start, end, deleteWord, deleteToStart, enter, escape

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
        guard text.count == 1, let character = text.first, Self.isPrintable(character) else { return nil }
        self = .character(character)
    }

    /// Whether `character` can go in a name: no control characters and no
    /// private-use ones (the function keys').
    static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
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
        case .deleteForward:
            guard cursor < text.count else { break }
            var chars = Array(text)
            chars.remove(at: cursor)
            text = String(chars)
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(text.count, cursor + 1)
        case .start: cursor = 0
        case .end: cursor = text.count
        case .deleteWord: remove(from: wordStart())
        case .deleteToStart: remove(from: 0)
        case .enter, .escape: break
        }
    }

    /// Inserts pasted or dropped text at the cursor: each printable Character,
    /// up to the first newline. Control and private-use characters (a tab)
    /// are left out.
    public mutating func insert(_ pasted: String) {
        var chars = Array(text)
        var at = cursor
        for character in pasted {
            if character.isNewline { break }
            guard PromptKey.isPrintable(character) else { continue }
            chars.insert(character, at: at)
            at += 1
        }
        text = String(chars)
        cursor = at
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
        case delete(path: String, question: DeleteQuestion)
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
        } else if folder.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            relative = String(folder.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        }
        return BrowserPrompt(kind: .add(folder: folder), line: PromptLine(), addLabel: "New: \(relative)/")
    }

    /// Starts with the current name so a small fix is a few keys.
    public static func rename(path: String) -> BrowserPrompt {
        BrowserPrompt(kind: .rename(path: path), line: PromptLine((path as NSString).lastPathComponent))
    }

    public static func delete(path: String, question: DeleteQuestion) -> BrowserPrompt {
        BrowserPrompt(kind: .delete(path: path, question: question), line: PromptLine())
    }

    /// "New: notes/" ("New: ./" for the root), "Rename: ", or the question.
    public var label: String {
        switch kind {
        case .add: addLabel
        case .rename: "Rename: "
        case .delete(_, let question): question.text
        }
    }

    /// What goes before an error, in place of the label: short, so the error
    /// always has the row. A delete question means nothing once answered.
    public var errorLabel: String {
        switch kind {
        case .add: "New: "
        case .rename: "Rename: "
        case .delete: "Delete: "
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

    /// Pasted text. Like any key it clears the error; in a delete question it
    /// cancels, since only `y` confirms one.
    public mutating func paste(_ text: String) -> Outcome {
        error = nil
        if case .delete = kind { return .cancelled }
        line.insert(text)
        return .editing
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

/// What `d` asks, in parts, so a row too narrow for all of it (the browser
/// beside the editor is about 33 columns) can shorten the name and the end
/// of the sentence and still say which item, and how to answer.
public struct DeleteQuestion: Equatable, Sendable {
    /// "Delete ", "Delete folder ", or "" when the name leads.
    public let before: String
    /// "notes.md", or "drafts/" for a folder.
    public let name: String
    /// "?", " and its 12 items?" or " has unsaved changes. Delete anyway?".
    public let after: String

    public static let answer = " (y/N)"
    /// A long name gives up its middle down to this many Characters while
    /// the words after it still show: enough to recognize it by.
    static let shortestName = 14
    /// While the unsaved warning is kept as ` has…`, the name may shrink to this.
    static let warningKeepsNameAt = 6

    public init(before: String, name: String, after: String) {
        self.before = before
        self.name = name
        self.after = after
    }

    public var text: String { before + name + after + Self.answer }

    /// The question as it fits in `width`, as `measure` measures text. The
    /// first of these that fits:
    ///
    /// 1. all of it;
    /// 2. the name losing its middle, down to `shortestName`;
    /// 3. the sentence losing words from its end (`has unsaved` stays longest),
    ///    the name at `shortestName`;
    /// 4. when nothing leads the name (the unsaved form): the first word of the
    ///    sentence and `…` (` has…`), the name shrinking from 13 to 6;
    /// 5. only the name and the answer, the name shortened as needed: after
    ///    `before`, then after a plain "Delete " (for a folder), each down to
    ///    `shortestName`; then with nothing before it, down to one Character.
    ///
    /// The answer, `(y/N)`, always ends it. Narrower than even that, all of it,
    /// for the row to clip.
    public func fitted(to width: Double, measure: (String) -> Double) -> String {
        func fits(_ candidate: String) -> Bool { measure(candidate) <= width }
        if fits(text) { return text }
        for length in stride(from: name.count - 1, through: Self.shortestName, by: -1) {
            let candidate = before + Self.shortened(name, to: length) + after + Self.answer
            if fits(candidate) { return candidate }
        }
        let shortName = Self.shortened(name, to: Self.shortestName)
        let wordEnds = Self.wordEnds(of: after)
        for end in wordEnds.reversed() {
            let candidate = before + shortName + after.prefix(end) + "…" + Self.answer
            if fits(candidate) { return candidate }
        }
        if before.isEmpty, let first = wordEnds.first {
            for length in stride(from: Self.shortestName - 1, through: Self.warningKeepsNameAt, by: -1) {
                let candidate = Self.shortened(name, to: length) + after.prefix(first) + "…" + Self.answer
                if fits(candidate) { return candidate }
            }
        }
        var prefixes = before.isEmpty ? [] : [before]
        if before == "Delete folder " { prefixes.append("Delete ") }
        prefixes.append("")
        for prefix in prefixes {
            let shortest = prefix.isEmpty ? 1 : min(name.count, Self.shortestName)
            for length in stride(from: name.count, through: shortest, by: -1) {
                let candidate = prefix + Self.shortened(name, to: length) + Self.answer
                if fits(candidate) { return candidate }
            }
        }
        return text
    }

    /// `name` in at most `length` Characters, its middle replaced by "…" so
    /// the start and the extension (or a folder's `/`) stay.
    private static func shortened(_ name: String, to length: Int) -> String {
        guard name.count > length else { return name }
        let visible = length - 1
        return name.prefix(visible - visible / 2) + "…" + name.suffix(visible / 2)
    }

    /// Where each word of `text` ends: the offsets of the spaces after the first.
    private static func wordEnds(of text: String) -> [Int] {
        text.enumerated().compactMap { offset, character in offset > 0 && character == " " ? offset : nil }
    }
}

/// Which key repeats the browser drops around its prompt. Held keys repeat
/// in the prompt as in vim's command line (Backspace, ← →), except:
///
/// - after the prompt opened or closed, until a fresh key goes down: holding
///   `a` mustn't type "aaa" into the new name, and holding Enter, Esc or a
///   window shortcut mustn't carry on into the browser. macOS repeats only
///   the most recently pressed key, so every repeat until the next key-down
///   belongs to the key that opened or closed the prompt;
/// - any key in a delete question, where a single key answers.
public struct PromptKeyRepeats: Equatable, Sendable {
    private var holding = false

    public init() {}

    /// Whether to drop this key-down. A key-down that isn't a repeat ends the hold.
    public mutating func drops(isRepeat: Bool, inDeleteQuestion: Bool) -> Bool {
        if isRepeat, holding || inDeleteQuestion { return true }
        if !isRepeat { holding = false }
        return false
    }

    /// The prompt just opened or closed, or was asked for (`d` waits to hear
    /// from nvim first): the key still held is the one that did it.
    public mutating func promptOpenedOrClosed() {
        holding = true
    }
}
