import Foundation

/// Events from the listener's thread, waiting for the main thread to take
/// them. A buffer event replaces one for the same file still waiting: when a
/// big file is edited faster than it renders, only its newest text is worth
/// drawing; likewise a colors event replaces a waiting one. Every other event keeps its place and order.
public final class PreviewEventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [PreviewEvent] = []

    public init() {}

    /// Adds an event, from any thread. True when the inbox was empty, so the
    /// caller arranges one `take()`; later posts ride along with it.
    public func post(_ event: PreviewEvent) -> Bool {
        lock.withLock {
            let wasEmpty = waiting.isEmpty
            if case let .buffer(snapshot) = event {
                waiting.removeAll { if case let .buffer(older) = $0 { older.path == snapshot.path } else { false } }
            }
            if case .colors = event {
                waiting.removeAll { if case .colors = $0 { true } else { false } }
            }
            waiting.append(event)
            return wasEmpty
        }
    }

    /// Everything waiting, oldest first, leaving the inbox empty.
    public func take() -> [PreviewEvent] {
        lock.withLock {
            defer { waiting.removeAll() }
            return waiting
        }
    }
}
