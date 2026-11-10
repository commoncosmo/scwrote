import Foundation

/// Reports what nvim does to the current file, for the preview. It has its
/// own connection to nvim, so waiting for events never holds up the app's
/// own requests.
public final class NvimEventListener: @unchecked Sendable {
    private let client: NvimClient

    public init(socketPath: String, connectTimeout: TimeInterval = 2) {
        // Waits out a slow nvim startup: until it's done, nvim takes the
        // connection but answers nothing.
        client = NvimClient(
            socketPath: socketPath, connectTimeout: connectTimeout, queuesNotifications: true, waitsOutTimeouts: true
        )
    }

    /// Connects, installs the autocommands, then calls `onEvent` on a
    /// background thread for each event, and `onEnd` once when nvim goes away
    /// or `stop()` is called. Call it once per listener.
    public func start(onEvent: @escaping @Sendable (PreviewEvent) -> Void, onEnd: @escaping @Sendable () -> Void) {
        let client = client
        let thread = Thread {
            defer { onEnd() }
            do {
                let channel = try client.channelID()
                _ = try client.request("nvim_exec_lua", [.string(PreviewAutocommands.lua), .array([.int(channel)])])
                while true {
                    let notification = try client.nextNotification()
                    if let event = PreviewEvent(method: notification.method, params: notification.params) {
                        onEvent(event)
                    }
                }
            } catch {
                // nvim exited, the install failed, or stop() closed the connection.
            }
        }
        thread.name = "scwrote nvim events"
        thread.start()
    }

    /// Disconnects from nvim; `onEnd` follows promptly. Safe from any thread.
    public func stop() {
        client.close()
    }
}
