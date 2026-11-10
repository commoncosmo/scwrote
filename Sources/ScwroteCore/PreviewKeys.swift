/// What a key does while the preview pane has focus.
public enum PreviewCommand: Equatable, Sendable {
    case lineDown, lineUp, halfPageDown, halfPageUp, top, bottom
    /// Move focus to the pane on the right, or open what is selected.
    case open
    /// Move focus back toward the editor.
    case close
    case toggle
    case leave
}

/// Turns keys into preview commands, holding the first `g` of `gg`.
public struct PreviewKeyReader: Sendable {
    private var pendingG = false

    public init() {}

    public mutating func read(_ key: BrowserKey) -> PreviewCommand? {
        if pendingG {
            pendingG = false
            if key == .character("g") { return .top }
        }
        switch key {
        case .character("j"), .down: return .lineDown
        case .character("k"), .up: return .lineUp
        case .halfPageDown: return .halfPageDown
        case .halfPageUp: return .halfPageUp
        case .character("G"): return .bottom
        case .character("g"):
            pendingG = true
            return nil
        case .character("l"), .right: return .open
        case .character("h"), .left: return .close
        case .enter, .character("o"): return .toggle
        case .escape: return .leave
        case .character: return nil
        }
    }
}
