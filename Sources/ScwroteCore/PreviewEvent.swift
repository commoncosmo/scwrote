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

/// Why a buffer came without its text.
public enum TextOmission: Equatable, Sendable {
    /// Larger than `PreviewLimits.maxBufferBytes`.
    case tooLarge
    /// Nobody needs it: the preview is hidden, or the file's kind isn't drawn
    /// from text (see `PreviewKind.needsText`).
    case notRequested
}

/// A file buffer as the preview sees it.
public struct BufferSnapshot: Equatable, Sendable {
    public var path: String
    public var filetype: String
    /// nil when it wasn't sent; `textOmission` says why.
    public var text: String?
    /// Why `text` is nil; nil when it isn't.
    public var textOmission: TextOmission?
    public var isModified: Bool
    public var cursor: CursorPosition

    /// Without a `textOmission`, missing text is taken to be too large.
    public init(
        path: String, filetype: String, text: String?, textOmission: TextOmission? = nil,
        isModified: Bool, cursor: CursorPosition
    ) {
        self.path = path
        self.filetype = filetype
        self.text = text
        self.textOmission = text == nil ? textOmission ?? .tooLarge : nil
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
    /// Buffers larger than this are reported without their text, as too large.
    public static let maxBufferBytes = 10_000_000
}

/// What nvim tells the preview, decoded from the `scwrote_preview`
/// notifications that `PreviewAutocommands` sends.
public enum PreviewEvent: Equatable, Sendable {
    /// The current file, sent on entering it, leaving insert mode, normal-mode
    /// changes and writes. Its text comes only when asked for (see
    /// `NvimEventListener.setSendsText`) and the file's kind needs it.
    case buffer(BufferSnapshot)
    /// The file's modified flag changed, which happens on the first keystroke.
    case modified(path: String, isModified: Bool)
    case cursor(path: String, CursorPosition)
    /// Every file with unsaved changes, sent whole (on install, renames and
    /// unloads) so a set built from `modified` events can't drift.
    case unsaved(Set<String>)
    /// The colors of nvim's colorscheme, sent on install and whenever the
    /// colorscheme or `background` changes (see `ColorAutocommands`).
    case colors(NvimColors)
    /// Whether scwrote owns `background`: sent once, after startup, by
    /// `BackgroundOwnership`. False when the user's config set it.
    case backgroundOwner(owned: Bool)

    static let method = "scwrote_preview"

    /// nil for other notifications and for params that don't fit the contract.
    public init?(method: String, params: [MessagePackValue]) {
        if method == NvimColors.method {
            guard let colors = NvimColors(params: params) else { return nil }
            self = .colors(colors)
            return
        }
        if method == BackgroundOwnership.method {
            guard params.count == 1, case let .map(fields) = params[0],
                  case let .bool(owned)? = fields[.string("owned")]
            else { return nil }
            self = .backgroundOwner(owned: owned)
            return
        }
        guard method == Self.method, params.count == 1, case let .map(fields) = params[0],
              case let .string(type)? = fields[.string("type")]
        else { return nil }
        if type == "unsaved" {
            // An empty Lua table arrives as an empty array or an empty map.
            switch fields[.string("paths")] {
            case let .array(values)?:
                var paths: Set<String> = []
                for value in values {
                    guard case let .string(path) = value else { return nil }
                    paths.insert(path)
                }
                self = .unsaved(paths)
            case let .map(pairs)? where pairs.isEmpty:
                self = .unsaved([])
            default:
                return nil
            }
            return
        }
        guard case let .string(path)? = fields[.string("path")] else { return nil }

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
            let omission: TextOmission = fields[.string("omitted")] == .string("not_requested") ? .notRequested : .tooLarge
            self = .buffer(BufferSnapshot(
                path: path, filetype: filetype, text: text, textOmission: omission, isModified: isModified, cursor: cursor
            ))
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
