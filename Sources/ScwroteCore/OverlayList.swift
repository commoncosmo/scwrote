/// A list the search overlay's state can drive: project search's matches or
/// quick open's files. The overlay owns the query and the vim keys; the list
/// owns its rows and its selection.
public protocol OverlayList: Equatable, Sendable {
    associatedtype Item: Equatable & Sendable

    init()
    var count: Int { get }
    var selectedIndex: Int? { get }
    var selected: Item? { get }
    mutating func move(by offset: Int)
    mutating func selectFirst()
    mutating func selectLast()
    var countLine: String { get }
}

extension SearchResults: OverlayList {
    public typealias Item = SearchMatch
    public var count: Int { matches.count }
}

extension QuickOpenResults: OverlayList {
    public typealias Item = QuickOpenRow
    public var count: Int { rows.count }
}
