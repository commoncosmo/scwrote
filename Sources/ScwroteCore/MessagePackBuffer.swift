/// Bytes read from a stream, handed out as whole MessagePack values. Each
/// value is decoded once it has all arrived: an incomplete one tells how many
/// bytes it needs, and decoding waits for them. So a large message that
/// arrives in many pieces costs about what it would all at once.
struct MessagePackBuffer {
    private var bytes: [UInt8] = []
    /// Bytes before this have been handed out.
    private var start = 0
    /// Decoding waits until this many unread bytes have arrived.
    private var needed = 1
    /// How many times `next()` ran the decoder, for tests.
    private(set) var decodeAttempts = 0

    mutating func append(_ chunk: some Collection<UInt8>) {
        bytes.append(contentsOf: chunk)
    }

    /// The next whole value, or nil until more bytes arrive.
    mutating func next() -> MessagePackValue? {
        guard bytes.count - start >= needed else { return nil }
        decodeAttempts += 1
        let decoded = bytes.withUnsafeBytes { MessagePackValue.decode(from: UnsafeRawBufferPointer(rebasing: $0[start...])) }
        switch decoded {
        case let .incomplete(needing):
            needed = needing
            return nil
        case let .value(value, length):
            start += length
            needed = 1
            // Drop what was handed out once it's most of the buffer, so the
            // copying stays in proportion to what arrives.
            if start == bytes.count {
                bytes.removeAll(keepingCapacity: bytes.count <= 1 << 20)
                start = 0
            } else if start > bytes.count / 2 {
                bytes.removeFirst(start)
                start = 0
            }
            return value
        }
    }

    mutating func removeAll() {
        bytes.removeAll()
        start = 0
        needed = 1
    }
}
