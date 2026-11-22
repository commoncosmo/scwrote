import Foundation

/// A file as the overlays' preview shows it: its lines, or why there are none.
public enum PreviewFile: Equatable, Sendable {
    /// The file's lines; only its first ones when `isWhole` is false.
    case text(lines: [Substring], isWhole: Bool)
    /// A NUL byte in the first `binaryProbeLength` bytes: ripgrep's own test.
    case binary
    /// Past the limit, when the whole file was asked for.
    case tooLarge

    /// Only the file's first lines: it must be read again for one deeper in.
    public var isPartial: Bool {
        if case .text(_, false) = self { return true }
        return false
    }

    /// How much of a file's start is looked at for a NUL byte, as ripgrep does.
    public static let binaryProbeLength = 8 * 1024

    /// Whether `head`, a file's first bytes, says the file is binary: a NUL
    /// byte within its first `binaryProbeLength` bytes.
    public static func isBinary(_ head: Data) -> Bool {
        head.prefix(binaryProbeLength).contains(0)
    }

    /// Reads the file at `path`: all of it up to `wholeLimit` bytes when
    /// `whole` (to center on a line anywhere in it), else only its first
    /// `headLength` bytes, enough to fill the preview from the top. A binary
    /// file is told from its first bytes alone, so it's never read further.
    /// A file that can't be read has no lines.
    public static func read(
        _ path: String, whole: Bool, headLength: Int = 64 * 1024, wholeLimit: Int = 8 * 1024 * 1024
    ) -> PreviewFile {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .text(lines: [], isWhole: true) }
        defer { try? handle.close() }
        let limit = whole ? wholeLimit : headLength
        // One byte past the limit says whether there's more.
        var data = (try? handle.read(upToCount: min(limit + 1, binaryProbeLength))) ?? Data()
        if isBinary(data) { return .binary }
        if data.count == binaryProbeLength, limit + 1 > data.count,
           let rest = try? handle.read(upToCount: limit + 1 - data.count) {
            data += rest
        }
        guard data.count > limit else { return .text(lines: lines(of: String(decoding: data, as: UTF8.self)), isWhole: true) }
        if whole { return .tooLarge }
        return .text(lines: lines(of: String(decoding: data.prefix(limit), as: UTF8.self)), isWhole: false)
    }

    /// `text`'s lines, without their `\n` or `\r\n` (one `Character` to
    /// Swift, so it's matched whole); a final line break doesn't start
    /// another line.
    public static func lines(of text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        let isBreak = { (c: Character) in c == "\n" || c == "\r\n" }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: isBreak)
        if let last = text.last, isBreak(last) { lines.removeLast() }
        return lines
    }
}
