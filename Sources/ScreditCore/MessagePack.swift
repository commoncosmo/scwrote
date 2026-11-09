import Foundation

/// MessagePack, the binary format Neovim's RPC speaks. Covers the whole format
/// for decoding (nvim may send any of it) and what requests need for encoding.
public indirect enum MessagePackValue: Hashable, Sendable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([MessagePackValue: MessagePackValue])
    case ext(type: Int8, data: Data)

    // MARK: - Encoding

    public func encoded() -> Data {
        var out = [UInt8]()
        encode(into: &out)
        return Data(out)
    }

    private func encode(into out: inout [UInt8]) {
        switch self {
        case .nil:
            out.append(0xC0)
        case let .bool(value):
            out.append(value ? 0xC3 : 0xC2)
        case let .int(value):
            Self.encodeInt(value, into: &out)
        case let .double(value):
            out.append(0xCB)
            Self.appendBigEndian(value.bitPattern, into: &out)
        case let .string(value):
            let utf8 = Array(value.utf8)
            Self.appendHeader(count: utf8.count, fix: 0xA0, fixLimit: 32, sized: (0xD9, 0xDA, 0xDB), into: &out)
            out += utf8
        case let .binary(value):
            Self.appendHeader(count: value.count, fix: nil, fixLimit: 0, sized: (0xC4, 0xC5, 0xC6), into: &out)
            out += value
        case let .array(values):
            Self.appendHeader(count: values.count, fix: 0x90, fixLimit: 16, sized: (nil, 0xDC, 0xDD), into: &out)
            for value in values { value.encode(into: &out) }
        case let .map(pairs):
            Self.appendHeader(count: pairs.count, fix: 0x80, fixLimit: 16, sized: (nil, 0xDE, 0xDF), into: &out)
            for (key, value) in pairs {
                key.encode(into: &out)
                value.encode(into: &out)
            }
        case let .ext(type, data):
            switch data.count {
            case 1: out.append(0xD4)
            case 2: out.append(0xD5)
            case 4: out.append(0xD6)
            case 8: out.append(0xD7)
            case 16: out.append(0xD8)
            default:
                Self.appendHeader(count: data.count, fix: nil, fixLimit: 0, sized: (0xC7, 0xC8, 0xC9), into: &out)
            }
            out.append(UInt8(bitPattern: type))
            out += data
        }
    }

    private static func encodeInt(_ value: Int64, into out: inout [UInt8]) {
        if value >= 0 {
            switch UInt64(value) {
            case 0...0x7F: out.append(UInt8(value))
            case 0...0xFF: out += [0xCC, UInt8(value)]
            case 0...0xFFFF: out.append(0xCD); appendBigEndian(UInt16(value), into: &out)
            case 0...0xFFFF_FFFF: out.append(0xCE); appendBigEndian(UInt32(value), into: &out)
            default: out.append(0xCF); appendBigEndian(UInt64(value), into: &out)
            }
        } else {
            switch value {
            case -32 ..< 0: out.append(UInt8(bitPattern: Int8(value)))
            case Int64(Int8.min) ..< 0: out += [0xD0, UInt8(bitPattern: Int8(value))]
            case Int64(Int16.min) ..< 0: out.append(0xD1); appendBigEndian(UInt16(bitPattern: Int16(value)), into: &out)
            case Int64(Int32.min) ..< 0: out.append(0xD2); appendBigEndian(UInt32(bitPattern: Int32(value)), into: &out)
            default: out.append(0xD3); appendBigEndian(UInt64(bitPattern: value), into: &out)
            }
        }
    }

    /// A length header: the "fix" form for small counts, then 8/16/32-bit forms.
    private static func appendHeader(
        count: Int, fix: UInt8?, fixLimit: Int, sized: (UInt8?, UInt8, UInt8), into out: inout [UInt8]
    ) {
        if let fix, count < fixLimit {
            out.append(fix | UInt8(count))
        } else if let byte8 = sized.0, count <= 0xFF {
            out += [byte8, UInt8(count)]
        } else if count <= 0xFFFF {
            out.append(sized.1)
            appendBigEndian(UInt16(count), into: &out)
        } else {
            out.append(sized.2)
            appendBigEndian(UInt32(count), into: &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, into out: inout [UInt8]) {
        withUnsafeBytes(of: value.bigEndian) { out += $0 }
    }

    // MARK: - Decoding

    /// The first value in `data` and how many bytes it used, or nil if `data`
    /// doesn't hold a complete value yet (more bytes are on the way).
    public static func decode(_ data: Data) -> (MessagePackValue, Int)? {
        var reader = Reader(bytes: [UInt8](data))
        guard let value = reader.value() else { return nil }
        return (value, reader.index)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func value() -> MessagePackValue? {
            guard let byte = take(1)?.first else { return nil }
            switch byte {
            case 0x00...0x7F: return .int(Int64(byte))
            case 0x80...0x8F: return map(count: Int(byte & 0x0F))
            case 0x90...0x9F: return array(count: Int(byte & 0x0F))
            case 0xA0...0xBF: return string(count: Int(byte & 0x1F))
            case 0xC0: return .nil
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return length(UInt8.self).flatMap { take($0) }.map { .binary(Data($0)) }
            case 0xC5: return length(UInt16.self).flatMap { take($0) }.map { .binary(Data($0)) }
            case 0xC6: return length(UInt32.self).flatMap { take($0) }.map { .binary(Data($0)) }
            case 0xC7: return length(UInt8.self).flatMap { ext(count: $0) }
            case 0xC8: return length(UInt16.self).flatMap { ext(count: $0) }
            case 0xC9: return length(UInt32.self).flatMap { ext(count: $0) }
            case 0xCA: return integer(UInt32.self).map { .double(Double(Float(bitPattern: $0))) }
            case 0xCB: return integer(UInt64.self).map { .double(Double(bitPattern: $0)) }
            case 0xCC: return integer(UInt8.self).map { .int(Int64($0)) }
            case 0xCD: return integer(UInt16.self).map { .int(Int64($0)) }
            case 0xCE: return integer(UInt32.self).map { .int(Int64($0)) }
            case 0xCF: return integer(UInt64.self).map { .int(Int64(bitPattern: $0)) }
            case 0xD0: return integer(UInt8.self).map { .int(Int64(Int8(bitPattern: $0))) }
            case 0xD1: return integer(UInt16.self).map { .int(Int64(Int16(bitPattern: $0))) }
            case 0xD2: return integer(UInt32.self).map { .int(Int64(Int32(bitPattern: $0))) }
            case 0xD3: return integer(UInt64.self).map { .int(Int64(bitPattern: $0)) }
            case 0xD4: return ext(count: 1)
            case 0xD5: return ext(count: 2)
            case 0xD6: return ext(count: 4)
            case 0xD7: return ext(count: 8)
            case 0xD8: return ext(count: 16)
            case 0xD9: return length(UInt8.self).flatMap { string(count: $0) }
            case 0xDA: return length(UInt16.self).flatMap { string(count: $0) }
            case 0xDB: return length(UInt32.self).flatMap { string(count: $0) }
            case 0xDC: return length(UInt16.self).flatMap { array(count: $0) }
            case 0xDD: return length(UInt32.self).flatMap { array(count: $0) }
            case 0xDE: return length(UInt16.self).flatMap { map(count: $0) }
            case 0xDF: return length(UInt32.self).flatMap { map(count: $0) }
            case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: byte)))
            default: return .nil // 0xC1 is never used
            }
        }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return bytes[index ..< index + count]
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            take(MemoryLayout<T>.size).map { $0.reduce(T(0)) { $0 << 8 | T($1) } }
        }

        mutating func length<T: FixedWidthInteger>(_ type: T.Type) -> Int? {
            integer(type).map { Int($0) }
        }

        mutating func string(count: Int) -> MessagePackValue? {
            take(count).map { .string(String(decoding: $0, as: UTF8.self)) }
        }

        mutating func array(count: Int) -> MessagePackValue? {
            var values: [MessagePackValue] = []
            values.reserveCapacity(min(count, 1024))
            for _ in 0 ..< count {
                guard let value = value() else { return nil }
                values.append(value)
            }
            return .array(values)
        }

        mutating func map(count: Int) -> MessagePackValue? {
            var pairs: [MessagePackValue: MessagePackValue] = [:]
            for _ in 0 ..< count {
                guard let key = value(), let value = value() else { return nil }
                pairs[key] = value
            }
            return .map(pairs)
        }

        mutating func ext(count: Int) -> MessagePackValue? {
            guard let type = take(1)?.first, let data = take(count) else { return nil }
            return .ext(type: Int8(bitPattern: type), data: Data(data))
        }
    }
}
