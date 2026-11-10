import Foundation
import Testing
@testable import ScwroteCore

struct MessagePackBufferTests {
    @Test func handsOutValuesInOrderOnceWhole() {
        let first = MessagePackValue.array([.int(2), .string("event"), .array([])]).encoded()
        let second = MessagePackValue.string("next").encoded()
        let stream = [UInt8](first + second)
        var buffer = MessagePackBuffer()

        buffer.append(stream[..<(first.count - 1)])
        #expect(buffer.next() == nil)
        buffer.append(stream[(first.count - 1) ..< (first.count + 2)])
        #expect(buffer.next() == .array([.int(2), .string("event"), .array([])]))
        #expect(buffer.next() == nil)
        buffer.append(stream[(first.count + 2)...])
        #expect(buffer.next() == .string("next"))
        #expect(buffer.next() == nil)
    }

    @Test func removeAllForgetsAPartialValue() {
        var buffer = MessagePackBuffer()
        buffer.append([UInt8](MessagePackValue.string("half").encoded().prefix(3)))
        buffer.removeAll()
        buffer.append([UInt8](MessagePackValue.int(7).encoded()))

        #expect(buffer.next() == .int(7))
    }

    /// A buffer's text from nvim arrives 64 KB at a time. Decoding must not
    /// start over on every piece: that made a 10 MB message cost seconds.
    @Test func aLargeMessageInManyPiecesIsDecodedOnce() {
        let text = String(repeating: "abcdefgh\n", count: 16_000_000 / 9)
        let message = [UInt8](MessagePackValue.array([.int(2), .string("scwrote_preview"), .array([
            .map([.string("type"): .string("buffer"), .string("text"): .string(text)]),
        ])]).encoded())
        var buffer = MessagePackBuffer()
        var decoded: [MessagePackValue] = []

        let started = Date()
        var offset = 0
        while offset < message.count {
            let end = min(offset + 64 * 1024, message.count)
            buffer.append(message[offset ..< end])
            offset = end
            while let value = buffer.next() { decoded.append(value) }
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(decoded.count == 1)
        // Once to learn how long the message is, once when it's all there.
        #expect(buffer.decodeAttempts <= 2)
        #expect(elapsed < 0.5, "took \(elapsed) s")
    }
}
