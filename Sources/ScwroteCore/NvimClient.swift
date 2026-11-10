import Foundation

/// A blocking msgpack-RPC client for a running nvim's `--listen` socket.
/// Calls block until nvim answers, so make them off the main thread.
///
/// A client made to listen (see `NvimEventListener`) queues the notifications
/// nvim sends for `nextNotification()`; since that waits for the next one, it
/// is used for nothing else. Other clients drop them: nvim broadcasts some to
/// every channel, and nobody would ever take them.
public final class NvimClient: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// The socket couldn't be reached before `connectTimeout`.
        case cannotConnect(String)
        /// The connection broke, or nvim didn't answer in time.
        case connectionLost
        /// nvim answered with an error.
        case nvim(String)
    }

    private let socketPath: String
    private let connectTimeout: TimeInterval
    /// Held for a whole call, including while it waits on nvim.
    private let lock = NSLock()
    /// Guards `socket` and `isClosed` for `close()`, which must not wait for
    /// `lock`: a call may be holding it while blocked in a read. Changing
    /// `socket` takes both locks, so either is enough to read it.
    private let closeLock = NSLock()
    private var socket: Int32 = -1
    private var isClosed = false
    private var nextRequestID: Int64 = 1
    private var received = MessagePackBuffer()
    private var notifications: [(method: String, params: [MessagePackValue])] = []
    private let queuesNotifications: Bool
    /// Whether a call waits as long as nvim takes to answer, rather than
    /// giving up after the socket's 5 s read timeout.
    private let waitsOutTimeouts: Bool

    /// `connectTimeout` covers nvim still starting up when the first request
    /// is made: until then the socket file may not exist yet.
    public convenience init(socketPath: String, connectTimeout: TimeInterval = 2) {
        self.init(socketPath: socketPath, connectTimeout: connectTimeout, queuesNotifications: false)
    }

    /// `queuesNotifications` keeps notifications for `nextNotification()`.
    /// `waitsOutTimeouts` makes calls wait however long nvim takes: it answers
    /// nothing until its startup is done, which plugins can stretch past 5 s.
    /// Either way a closed connection ends a call at once.
    init(socketPath: String, connectTimeout: TimeInterval = 2, queuesNotifications: Bool, waitsOutTimeouts: Bool = false) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
        self.queuesNotifications = queuesNotifications
        self.waitsOutTimeouts = waitsOutTimeouts
    }

    /// How many notifications wait for `nextNotification()`, for tests.
    var queuedNotificationCount: Int { lock.withLock { notifications.count } }

    deinit {
        if socket >= 0 { Darwin.close(socket) }
    }

    public func request(_ method: String, _ params: [MessagePackValue]) throws -> MessagePackValue {
        lock.lock()
        defer { lock.unlock() }
        if socket < 0 { try connect() }

        let id = nextRequestID
        nextRequestID += 1
        do {
            try send(MessagePackValue.array([.int(0), .int(id), .string(method), .array(params)]).encoded())
            return try response(to: id)
        } catch Failure.connectionLost {
            disconnect()
            throw Failure.connectionLost
        }
    }

    /// The next notification nvim sent, waiting as long as it takes. Throws
    /// `.connectionLost` when nvim goes away or the client is closed. Only for
    /// a client that queues notifications.
    public func nextNotification() throws -> (method: String, params: [MessagePackValue]) {
        precondition(queuesNotifications, "this client drops notifications")
        lock.lock()
        defer { lock.unlock() }
        if socket < 0 { try connect() }

        do {
            while notifications.isEmpty {
                _ = receiveBuffered(until: { _ in false })
                if notifications.isEmpty { try readMore(waitingOutTimeouts: true) }
            }
            return notifications.removeFirst()
        } catch Failure.connectionLost {
            disconnect()
            throw Failure.connectionLost
        }
    }

    /// Closes the connection for good, from any thread. A call waiting on nvim
    /// returns at once with `.connectionLost`, and later calls throw it too.
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        isClosed = true
        // Wakes a blocked read with end-of-file. The fd itself is closed by
        // the thread holding `lock`, so it can't be reused under that read.
        if socket >= 0 { shutdown(socket, SHUT_RDWR) }
    }

    // MARK: - nvim commands

    /// `:edit` the file. The path is passed as data, never spliced into a
    /// command, so names with spaces or quotes are safe.
    public func edit(_ path: String) throws {
        _ = try request("nvim_exec_lua", [
            .string("vim.cmd.edit(vim.fn.fnameescape(...))"),
            .array([.string(path)]),
        ])
    }

    /// Full path of the current buffer, or nil if it has no file.
    public func currentFile() throws -> String? {
        guard case let .string(name) = try request("nvim_buf_get_name", [.int(0)]), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// The ID nvim gave this connection, for `rpcnotify()` to address it.
    public func channelID() throws -> Int64 {
        guard case let .array(info) = try request("nvim_get_api_info", []),
              case let .int(id)? = info.first
        else { throw Failure.nvim("nvim_get_api_info gave no channel ID") }
        return id
    }

    // MARK: - Socket

    private func connect() throws {
        let deadline = Date().addingTimeInterval(connectTimeout)
        while true {
            if let fd = Self.open(socketPath) {
                closeLock.lock()
                defer { closeLock.unlock() }
                guard !isClosed else {
                    Darwin.close(fd)
                    throw Failure.connectionLost
                }
                socket = fd
                received.removeAll()
                notifications.removeAll()
                return
            }
            if closeLock.withLock({ isClosed }) { throw Failure.connectionLost }
            guard Date() < deadline else { throw Failure.cannotConnect(socketPath) }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func open(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        // Writing to a closed socket should fail, not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Don't wait forever on an nvim that stopped answering.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func disconnect() {
        closeLock.withLock {
            if socket >= 0 { Darwin.close(socket) }
            socket = -1
        }
        received.removeAll()
    }

    private func send(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw Failure.connectionLost }
                offset += written
            }
        }
    }

    /// Reads messages until the response to `id` arrives. Notifications that
    /// come meanwhile are queued or dropped; anything else (requests to us,
    /// responses to calls that failed) is skipped.
    private func response(to id: Int64) throws -> MessagePackValue {
        while true {
            if let parts = receiveBuffered(until: { $0.count == 4 && $0[0] == .int(1) && $0[1] == .int(id) }) {
                if parts[2] != .nil { throw Failure.nvim(Self.describe(parts[2])) }
                return parts[3]
            }
            try readMore(waitingOutTimeouts: waitsOutTimeouts)
        }
    }

    /// Decodes the messages already read, queueing notifications (or dropping
    /// them, unless `queuesNotifications`), until
    /// `isWanted` accepts one of the others, which it returns. nil when the
    /// buffer runs out first.
    private func receiveBuffered(until isWanted: ([MessagePackValue]) -> Bool) -> [MessagePackValue]? {
        while let message = received.next() {
            guard case let .array(parts) = message else { continue }
            if parts.count == 3, parts[0] == .int(2),
               case let .string(method) = parts[1], case let .array(params) = parts[2] {
                if queuesNotifications { notifications.append((method, params)) }
                continue
            }
            if isWanted(parts) { return parts }
        }
        return nil
    }

    /// Appends at least one more chunk from the socket to `received`. A read
    /// timeout throws, unless `waitingOutTimeouts`, when it means keep waiting.
    private func readMore(waitingOutTimeouts: Bool) throws {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count > 0 {
                received.append(chunk[..<count])
                return
            }
            let timedOut = count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            guard waitingOutTimeouts, timedOut else { throw Failure.connectionLost }
        }
    }

    /// nvim errors arrive as [type, message].
    private static func describe(_ error: MessagePackValue) -> String {
        if case let .array(parts) = error, parts.count == 2, case let .string(message) = parts[1] {
            return message
        }
        return "\(error)"
    }
}
