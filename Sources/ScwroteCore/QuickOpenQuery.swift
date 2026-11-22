/// What the user typed into quick open: a name to fuzzy-match, and optionally
/// a line to open the file at ("Theme.swift:115").
public struct QuickOpenQuery: Equatable, Sendable {
    /// The text to match against paths, without any `:line` suffix.
    public let name: String
    /// 1-based. Nil when the text has no trailing `:digits`.
    public let line: Int?

    /// True when `name` has no non-space characters.
    public var isEmpty: Bool { !name.contains { $0 != " " } }

    /// Splits off a trailing `:` and ASCII digits, only the last colon
    /// counting. Digits that do not fit an `Int` leave the text whole, and
    /// line 0 becomes 1.
    public init(_ text: String) {
        if let colon = text.lastIndex(of: ":") {
            let digits = text[text.index(after: colon)...]
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
               let number = Int(digits) {
                self.init(name: String(text[..<colon]), line: max(number, 1))
                return
            }
        }
        self.init(name: text, line: nil)
    }

    init(name: String, line: Int?) {
        self.name = name
        self.line = line
    }
}
