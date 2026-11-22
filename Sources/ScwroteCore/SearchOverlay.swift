import Foundation

/// A key the search overlay understands. The view turns `NSEvent`s into these.
/// While typing, `character` is text for the query; in the list it is a vim
/// command.
public enum SearchKey: Equatable, Sendable {
    case character(Character)
    /// Backspace, ←/→, Ctrl-W, Home/End… (typing mode).
    case edit(PromptKey)
    /// Ctrl-J / ↓, Ctrl-K / ↑.
    case next, previous
    /// Ctrl-D, Ctrl-U.
    case halfPageDown, halfPageUp
    case enter, escape
    /// Ctrl-Q: send every match to nvim's quickfix list.
    case sendToQuickfix
}

/// What the overlay asks of whoever owns it.
public enum SearchAction<Item: Equatable & Sendable>: Equatable, Sendable {
    case queryChanged(String)
    case open(Item)
    case close
    /// Quick open: show or hide hidden files.
    case toggleHidden
    /// Project search: send every match to nvim's quickfix list.
    case sendToQuickfix
}

/// Which of the overlay's two modes is active.
public enum SearchOverlayMode: Equatable, Sendable { case typing, list }

/// The overlay's state over any result list: the query, which of its two modes is
/// active (typing in the query, or vim keys over the result list), and the
/// results. Pure; the view draws it and runs the actions.
public struct SearchOverlay<List: OverlayList>: Equatable, Sendable {
    public typealias Mode = SearchOverlayMode

    public private(set) var query = PromptLine()
    public private(set) var mode = Mode.typing
    /// After `reopen()`: the next typed character replaces the query.
    public private(set) var isQuerySelected = false
    public var results = List()

    /// A `g` waiting for its second, in list mode.
    private var pendingG = false

    public init() {}

    /// Typing mode with the old query kept and selected, so typing starts a
    /// new search and an arrow key edits the old one.
    public mutating func reopen() {
        mode = .typing
        isQuerySelected = true
        pendingG = false
    }

    public mutating func handle(_ key: SearchKey, pageHeight: Int) -> SearchAction<List.Item>? {
        switch key {
        case .edit(.enter): return handle(.enter, pageHeight: pageHeight)
        case .edit(.escape): return handle(.escape, pageHeight: pageHeight)
        case .edit(.character(let c)): return handle(.character(c), pageHeight: pageHeight)
        default: break
        }
        let wasPendingG = pendingG
        pendingG = false
        switch key {
        case .next:
            results.move(by: 1)
            return nil
        case .previous:
            results.move(by: -1)
            return nil
        case .enter:
            return results.selected.map(SearchAction<List.Item>.open)
        case .sendToQuickfix:
            return query.text.isEmpty ? nil : .sendToQuickfix
        case .escape:
            return escape()
        case .edit(let edit):
            return mode == .typing ? editQuery(edit) : nil
        case .halfPageUp where mode == .typing:
            return editQuery(.deleteToStart)
        case .halfPageDown where mode == .typing:
            return nil
        case .halfPageDown:
            results.move(by: max(1, pageHeight / 2))
            return nil
        case .halfPageUp:
            results.move(by: -max(1, pageHeight / 2))
            return nil
        case .character(let c):
            if mode == .typing { return editQuery(.character(c)) }
            switch c {
            case "j": results.move(by: 1)
            case "k": results.move(by: -1)
            case "G": results.selectLast()
            case "g":
                if wasPendingG { results.selectFirst() } else { pendingG = true }
            case "i", "/": mode = .typing
            default: break
            }
            return nil
        }
    }

    /// Pasted text, its line breaks as spaces, at the cursor (or over a
    /// selected query).
    public mutating func paste(_ text: String) -> SearchAction<List.Item>? {
        pendingG = false
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .map { $0.isNewline ? " " : $0 }
        return change { line in line.insert(String(flat)) }
    }

    /// The hidden-files key (quick open only; the view decides).
    public mutating func toggleHidden() -> SearchAction<List.Item> {
        pendingG = false
        return .toggleHidden
    }

    private mutating func escape() -> SearchAction<List.Item>? {
        switch mode {
        case .typing:
            mode = .list
            isQuerySelected = false
            return nil
        case .list:
            return .close
        }
    }

    private mutating func editQuery(_ key: PromptKey) -> SearchAction<List.Item>? {
        if isQuerySelected {
            switch key {
            case .left, .start:
                isQuerySelected = false
                query.edit(.start)
                return nil
            case .right, .end:
                isQuerySelected = false
                query.edit(.end)
                return nil
            default: break
            }
        }
        return change { line in line.edit(key) }
    }

    /// Applies `edit` to the query (to an empty one if it was selected) and
    /// reports the new text if it differs.
    private mutating func change(_ edit: (inout PromptLine) -> Void) -> SearchAction<List.Item>? {
        let before = query.text
        var line = query
        if isQuerySelected { line = PromptLine() }
        edit(&line)
        isQuerySelected = false
        query = line
        return query.text == before ? nil : .queryChanged(query.text)
    }
}

public typealias TextSearchOverlay = SearchOverlay<SearchResults>
public typealias QuickOpenOverlay = SearchOverlay<QuickOpenResults>
