/// Where the cursor is: `line` counts from 1, `column` from 0 in characters
/// (not bytes), so it can index the buffer text directly.
public struct CursorPosition: Equatable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// A file buffer as the preview sees it.
public struct BufferSnapshot: Equatable, Sendable {
    public var path: String
    public var filetype: String
    /// nil when the buffer is larger than `PreviewLimits.maxBufferBytes`.
    public var text: String?
    public var isModified: Bool
    public var cursor: CursorPosition

    public init(path: String, filetype: String, text: String?, isModified: Bool, cursor: CursorPosition) {
        self.path = path
        self.filetype = filetype
        self.text = text
        self.isModified = isModified
        self.cursor = cursor
    }

    /// How many lines the text has; 1 when it wasn't sent. Counts bytes, not
    /// characters, so it stays cheap on large buffers.
    public var lineCount: Int {
        guard let text else { return 1 }
        return text.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }
}

public enum PreviewLimits {
    /// Buffers larger than this are reported without their text.
    public static let maxBufferBytes = 10_000_000
}

/// What nvim tells the preview, decoded from the `scwrote_preview`
/// notifications that `PreviewAutocommands` sends.
public enum PreviewEvent: Equatable, Sendable {
    /// The current file's text, sent on entering it, leaving insert mode,
    /// normal-mode changes and writes.
    case buffer(BufferSnapshot)
    /// The file's modified flag changed, which happens on the first keystroke.
    case modified(path: String, isModified: Bool)
    case cursor(path: String, CursorPosition)

    static let method = "scwrote_preview"

    /// nil for other notifications and for params that don't fit the contract.
    public init?(method: String, params: [MessagePackValue]) {
        guard method == Self.method, params.count == 1, case let .map(fields) = params[0],
              case let .string(type)? = fields[.string("type")],
              case let .string(path)? = fields[.string("path")]
        else { return nil }

        func bool(_ key: String) -> Bool? {
            if case let .bool(value)? = fields[.string(key)] { value } else { nil }
        }
        func int(_ key: String) -> Int? {
            if case let .int(value)? = fields[.string(key)] { Int(value) } else { nil }
        }
        func cursor() -> CursorPosition? {
            guard let line = int("line"), let column = int("column") else { return nil }
            return CursorPosition(line: line, column: column)
        }

        switch type {
        case "buffer":
            guard case let .string(filetype)? = fields[.string("filetype")],
                  let isModified = bool("modified"), let cursor = cursor()
            else { return nil }
            var text: String?
            if case let .string(value)? = fields[.string("text")] { text = value }
            self = .buffer(BufferSnapshot(path: path, filetype: filetype, text: text, isModified: isModified, cursor: cursor))
        case "modified":
            guard let isModified = bool("modified") else { return nil }
            self = .modified(path: path, isModified: isModified)
        case "cursor":
            guard let cursor = cursor() else { return nil }
            self = .cursor(path: path, cursor)
        default:
            return nil
        }
    }
}
