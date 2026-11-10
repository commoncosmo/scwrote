/// What the preview's header strip shows.
public struct PreviewHeader: Equatable, Sendable {
    /// "README.md · Markdown", "Main.swift · no preview" or "No file".
    public var label: String
    public var isUnsaved: Bool
    /// An error or note, without the warning sign.
    public var message: String?
    public var isError: Bool
    /// The shown HTML references remote content that was kept from loading.
    /// The pane sets it; `PreviewState` doesn't know.
    public var remoteContentBlocked: Bool

    public init(label: String, isUnsaved: Bool, message: String?, isError: Bool, remoteContentBlocked: Bool = false) {
        self.label = label
        self.isUnsaved = isUnsaved
        self.message = message
        self.isError = isError
        self.remoteContentBlocked = remoteContentBlocked
    }
}

/// What the host must do after the preview state changed.
public enum PreviewEffect: Equatable, Sendable {
    /// Render the target again.
    case render
    /// Only the header changed.
    case headerOnly
    /// Scroll the preview to the editor's cursor.
    case follow(CursorPosition)
    case nothing
}

/// Which file the preview shows, and the header that describes it. Pure
/// state driven by nvim's events and by the user picking an image or PDF.
public struct PreviewState: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case none
        case buffer(BufferSnapshot)
        /// A file picked in the browser that is only shown, never edited.
        case viewOnly(path: String)
    }

    private static let tooLarge = "too large to preview"

    public private(set) var target: Target = .none
    /// The newest buffer nvim reported, kept while a view-only file is shown
    /// so that returning to the editor needs no new event.
    private var lastBuffer: BufferSnapshot?
    private var message: String?
    private var isError = false

    public init() {}

    public var kind: PreviewKind {
        switch target {
        case .none: .unsupported
        case let .buffer(snapshot):
            PreviewKind(path: snapshot.path, filetype: snapshot.filetype.isEmpty ? nil : snapshot.filetype)
        case let .viewOnly(path): PreviewKind(path: path)
        }
    }

    /// The shown buffer is drawn from text it came without, because the
    /// preview was hidden when it was sent: the text is on its way (the
    /// listener sends the buffer again when asked for it), so don't draw yet.
    public var isAwaitingText: Bool {
        guard case let .buffer(snapshot) = target else { return false }
        return snapshot.textOmission == .notRequested && kind.needsText
    }

    public var header: PreviewHeader {
        var label = "No file"
        var isUnsaved = false
        switch target {
        case .none: break
        case let .buffer(snapshot):
            label = Self.label(path: snapshot.path, kind: kind)
            isUnsaved = snapshot.isModified
        case let .viewOnly(path):
            label = Self.label(path: path, kind: kind)
        }
        return PreviewHeader(label: label, isUnsaved: isUnsaved, message: message, isError: isError)
    }

    private static func label(path: String, kind: PreviewKind) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return "\(name) · \(kind.displayName)"
    }

    public mutating func apply(_ event: PreviewEvent) -> PreviewEffect {
        switch event {
        case let .buffer(snapshot):
            let previous = lastBuffer
            lastBuffer = snapshot
            if case .viewOnly = target, previous?.path == snapshot.path { return .nothing }
            show(.buffer(snapshot), keepingMessage: previous?.path == snapshot.path)
            return .render

        case let .modified(path, isModified):
            if lastBuffer?.path == path { lastBuffer?.isModified = isModified }
            if case var .buffer(snapshot) = target, snapshot.path == path {
                snapshot.isModified = isModified
                target = .buffer(snapshot)
                return .headerOnly
            }
            return .nothing

        case let .cursor(path, position):
            if case let .buffer(snapshot) = target, snapshot.path == path { return .follow(position) }
            return .nothing
        }
    }

    public mutating func pickViewOnly(_ path: String) -> PreviewEffect {
        show(.viewOnly(path: path), keepingMessage: false)
        return .render
    }

    public mutating func returnToEditor() -> PreviewEffect {
        guard case .viewOnly = target else { return .nothing }
        if let lastBuffer {
            show(.buffer(lastBuffer), keepingMessage: false)
        } else {
            show(.none, keepingMessage: false)
        }
        return .render
    }

    /// The renderer's verdict on the last render. An error wins over a note;
    /// neither clears the message.
    public mutating func rendered(error: String?, note: String?) {
        if let error {
            message = error
            isError = true
        } else {
            message = note
            isError = false
        }
    }

    private mutating func show(_ newTarget: Target, keepingMessage: Bool) {
        target = newTarget
        if !keepingMessage || message == Self.tooLarge { message = nil; isError = false }
        if case let .buffer(snapshot) = newTarget, snapshot.textOmission == .tooLarge {
            message = Self.tooLarge
            isError = false
        }
    }
}
