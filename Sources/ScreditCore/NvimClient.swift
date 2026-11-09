import Foundation

/// A message nvim sends on its own, such as `rpcnotify(channel, method, ...)`.
public struct NvimNotification: Equatable, Sendable {
    public let method: String
    public let params: [MessagePackValue]

    public init(method: String, params: [MessagePackValue]) {
        self.method = method
        self.params = params
    }
}

/// A blocking msgpack-RPC client for a running nvim's `--listen` socket.
/// Calls block until nvim answers, so make them off the main thread.
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
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var nextRequestID: Int64 = 1
    private var received = Data()
    /// Notifications that arrived while waiting for an answer.
    private var notifications: [NvimNotification] = []

    /// The socket's receive timeout passed with nothing to read.
    private struct ReadTimeout: Error {}

    /// `connectTimeout` covers nvim still starting up when the first request
    /// is made: until then the socket file may not exist yet.
    public init(socketPath: String, connectTimeout: TimeInterval = 2) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
    }

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

    /// Waits for nvim's next notification. Nil if `timeout` passes first;
    /// without one, waits as long as nvim runs. Holds the connection while it
    /// waits, so listen on a client of its own.
    public func nextNotification(timeout: TimeInterval? = nil) throws -> NvimNotification? {
        lock.lock()
        defer { lock.unlock() }
        if socket < 0 { try connect() }

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while notifications.isEmpty {
            do {
                keepIfNotification(try nextMessage())
            } catch is ReadTimeout {
                if let deadline, Date() >= deadline { return nil }
            } catch {
                disconnect()
                throw error
            }
        }
        return notifications.removeFirst()
    }

    // MARK: - nvim commands

    /// This connection's channel in nvim, for `rpcnotify` to reach it.
    public func channelID() throws -> Int64 {
        guard case let .array(info) = try request("nvim_get_api_info", []), case let .int(id)? = info.first else {
            throw Failure.nvim("unexpected reply to nvim_get_api_info")
        }
        return id
    }

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

    // MARK: - Socket

    private func connect() throws {
        let deadline = Date().addingTimeInterval(connectTimeout)
        while true {
            if let fd = Self.open(socketPath) {
                socket = fd
                received.removeAll()
                return
            }
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
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
        received.removeAll()
        notifications.removeAll()
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
    /// come first are kept for `nextNotification`; anything else is skipped.
    private func response(to id: Int64) throws -> MessagePackValue {
        while true {
            let message: MessagePackValue
            do {
                message = try nextMessage()
            } catch is ReadTimeout {
                throw Failure.connectionLost
            }
            keepIfNotification(message)
            guard case let .array(parts) = message, parts.count == 4,
                  parts[0] == .int(1), parts[1] == .int(id)
            else { continue }
            if parts[2] != .nil { throw Failure.nvim(Self.describe(parts[2])) }
            return parts[3]
        }
    }

    /// The next whole message, reading from the socket as needed.
    private func nextMessage() throws -> MessagePackValue {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let (message, length) = MessagePackValue.decode(received) {
                received.removeFirst(length)
                return message
            }
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw ReadTimeout() }
            guard count > 0 else { throw Failure.connectionLost }
            received.append(contentsOf: chunk[..<count])
        }
    }

    /// Notifications arrive as [2, method, params].
    private func keepIfNotification(_ message: MessagePackValue) {
        guard case let .array(parts) = message, parts.count == 3, parts[0] == .int(2),
              case let .string(method) = parts[1], case let .array(params) = parts[2]
        else { return }
        notifications.append(NvimNotification(method: method, params: params))
    }

    /// nvim errors arrive as [type, message].
    private static func describe(_ error: MessagePackValue) -> String {
        if case let .array(parts) = error, parts.count == 2, case let .string(message) = parts[1] {
            return message
        }
        return "\(error)"
    }
}
