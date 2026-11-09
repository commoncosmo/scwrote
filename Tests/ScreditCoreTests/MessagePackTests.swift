import Foundation
import Testing
@testable import ScreditCore

private func bytes(_ values: UInt8...) -> [UInt8] { values }

struct MessagePackEncodingTests {
    @Test func encodesAnNvimRequest() {
        let request = MessagePackValue.array([.int(0), .int(1), .string("nvim_eval"), .array([])])

        #expect([UInt8](request.encoded()) == bytes(0x94, 0x00, 0x01, 0xA9) + Array("nvim_eval".utf8) + [0x90])
    }

    @Test(arguments: [
        (MessagePackValue.nil, [UInt8](arrayLiteral: 0xC0)),
        (.bool(true), [0xC3]),
        (.bool(false), [0xC2]),
        (.int(127), [0x7F]),
        (.int(200), [0xCC, 0xC8]),
        (.int(70000), [0xCE, 0x00, 0x01, 0x11, 0x70]),
        (.int(-1), [0xFF]),
        (.int(-100), [0xD0, 0x9C]),
    ])
    func encodesScalars(value: MessagePackValue, expected: [UInt8]) {
        #expect([UInt8](value.encoded()) == expected)
    }

    @Test func encodesStringsLongerThanAFixstrWithALengthByte() {
        let text = String(repeating: "a", count: 40)

        #expect([UInt8](MessagePackValue.string(text).encoded()) == bytes(0xD9, 40) + Array(text.utf8))
    }
}

struct MessagePackDecodingTests {
    @Test func decodesAnNvimResponse() throws {
        let data = Data(bytes(0x94, 0x01, 0x07, 0xC0, 0xA4) + Array("a.md".utf8))

        let (value, length) = try #require(MessagePackValue.decode(data))

        #expect(value == .array([.int(1), .int(7), .nil, .string("a.md")]))
        #expect(length == data.count)
    }

    @Test func roundTripsNestedValues() throws {
        let value = MessagePackValue.array([
            .string(String(repeating: "x", count: 300)),
            .int(-70000), .int(1 << 40), .bool(true), .nil,
            .map([.string("k"): .array([.int(1), .int(2)])]),
        ])

        let (decoded, _) = try #require(MessagePackValue.decode(value.encoded()))

        #expect(decoded == value)
    }

    @Test func decodesNvimBufferHandlesAsExtensionValues() throws {
        // nvim sends a Buffer as ext type 0 holding the handle number.
        let (value, _) = try #require(MessagePackValue.decode(Data(bytes(0xD4, 0x00, 0x01))))

        #expect(value == .ext(type: 0, data: Data([0x01])))
    }

    @Test func decodesFloats() throws {
        let (value, _) = try #require(MessagePackValue.decode(Data(bytes(0xCB, 0x3F, 0xF8, 0, 0, 0, 0, 0, 0))))

        #expect(value == .double(1.5))
    }

    /// Bytes arrive from the socket in pieces: an incomplete message is "not yet".
    @Test func returnsNilUntilTheWholeMessageHasArrived() {
        let full = MessagePackValue.array([.int(1), .string("hello")]).encoded()

        for cut in 0..<full.count {
            #expect(MessagePackValue.decode(full.prefix(cut)) == nil)
        }
    }

    @Test func reportsHowManyBytesTheFirstMessageUsed() throws {
        let first = MessagePackValue.int(5).encoded()
        let second = MessagePackValue.string("next").encoded()

        let (_, length) = try #require(MessagePackValue.decode(first + second))

        #expect(length == first.count)
    }
}
