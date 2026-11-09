import Foundation

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

    /// Reads messages until the response to `id` arrives. Anything else nvim
    /// sends meanwhile (notifications, requests to us) is skipped.
    private func response(to id: Int64) throws -> MessagePackValue {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let (message, length) = MessagePackValue.decode(received) {
                received.removeFirst(length)
                guard case let .array(parts) = message, parts.count == 4,
                      parts[0] == .int(1), parts[1] == .int(id)
                else { continue }
                if parts[2] != .nil { throw Failure.nvim(Self.describe(parts[2])) }
                return parts[3]
            }
            let count = Darwin.read(socket, &chunk, chunk.count)
            guard count > 0 else { throw Failure.connectionLost }
            received.append(contentsOf: chunk[..<count])
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
