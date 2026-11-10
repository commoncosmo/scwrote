import Foundation

/// Reports what nvim does to the current file, for the preview. It has its
/// own connections to nvim, so waiting for events never holds up the app's
/// own requests: one only listens, the other installs and reinstalls the
/// autocommands that report to it.
public final class NvimEventListener: @unchecked Sendable {
    /// Waits for events; a thread blocks on it in `nextNotification()`.
    private let events: NvimClient
    /// Installs the autocommands, one call at a time, on `controlQueue`.
    private let control: NvimClient
    private let controlQueue = DispatchQueue(label: "scwrote.nvim-events.control")
    private let lock = NSLock()
    /// The listening connection's channel, once nvim has said it.
    private var channel: Int64?
    private var sendsText = false

    public init(socketPath: String, connectTimeout: TimeInterval = 2) {
        // Both wait out a slow nvim startup: until it's done, nvim takes
        // connections but answers nothing.
        events = NvimClient(
            socketPath: socketPath, connectTimeout: connectTimeout, queuesNotifications: true, waitsOutTimeouts: true
        )
        control = NvimClient(
            socketPath: socketPath, connectTimeout: connectTimeout, queuesNotifications: false, waitsOutTimeouts: true
        )
    }

    /// Connects, installs the autocommands, then calls `onEvent` on a
    /// background thread for each event, and `onEnd` once when nvim goes away,
    /// the install fails, or `stop()` is called. Call it once per listener.
    public func start(onEvent: @escaping @Sendable (PreviewEvent) -> Void, onEnd: @escaping @Sendable () -> Void) {
        let events = events
        let thread = Thread { [self] in
            defer { onEnd() }
            do {
                let channel = try events.channelID()
                lock.withLock { self.channel = channel }
                install()
                while true {
                    let notification = try events.nextNotification()
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

    /// Whether buffer events carry the file's text. Off at first: the app
    /// turns it on while the preview shows. Each change sends the current
    /// buffer again, so turning it on brings the text at once. Returns at
    /// once; safe from any thread.
    public func setSendsText(_ on: Bool) {
        let changed = lock.withLock {
            defer { sendsText = on }
            return sendsText != on
        }
        if changed { install() }
    }

    /// Disconnects from nvim; `onEnd` follows promptly. Safe from any thread.
    public func stop() {
        events.close()
        control.close()
    }

    /// (Re)installs the autocommands with the newest settings, once the
    /// channel is known. A failure ends the listener.
    private func install() {
        controlQueue.async { [self] in
            guard let (channel, sendsText) = lock.withLock({ channel.map { ($0, sendsText) } }) else { return }
            do {
                _ = try control.request(
                    "nvim_exec_lua",
                    [.string(PreviewAutocommands.lua), .array(PreviewAutocommands.arguments(channel: channel, sendsText: sendsText))]
                )
            } catch {
                stop()
            }
        }
    }
}
