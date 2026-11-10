/// The HTML files whose remote content the user said to load, by path. Kept
/// by the window, so consent ends when the window closes; nothing is saved.
public struct RemoteContentConsent: Equatable, Sendable {
    private var allowed: Set<String> = []

    public init() {}

    public func isAllowed(_ path: String) -> Bool {
        allowed.contains(path)
    }

    public mutating func allow(_ path: String) {
        allowed.insert(path)
    }
}
