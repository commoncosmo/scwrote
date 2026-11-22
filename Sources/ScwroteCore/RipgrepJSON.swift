import Foundation

/// Reads ripgrep's `--json` output, one message per line.
public enum RipgrepJSON {
    /// The longest `text` a match shows, counting the "…" cut markers.
    static let maxTextLength = 200
    /// How much of the line to keep before the first match when cutting.
    static let leadingContext = 40

    /// The match on one `--json` output line, or nil for any other message type.
    /// `root` is the nvim-form folder the relative path joins to; `label`, when
    /// given (stdin searches), replaces the path ripgrep reports.
    public static func match(from line: Data, root: String, label: String? = nil) -> SearchMatch? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["type"] as? String == "match",
              let data = message["data"] as? [String: Any],
              let reported = string(data["path"]),
              let lineNumber = data["line_number"] as? Int,
              let fullLine = string(data["lines"])
        else { return nil }

        let path = label ?? (reported.hasPrefix("/") ? reported : root + "/" + reported)
        let offsets: [Range<Int>] = (data["submatches"] as? [[String: Any]] ?? []).compactMap {
            guard let start = $0["start"] as? Int, let end = $0["end"] as? Int, start <= end else { return nil }
            return start..<end
        }
        let (text, ranges) = display(fullLine, matches: offsets)
        var lineText = Substring(fullLine)
        // "\r\n" is one Character, so this drops either line ending.
        while lineText.last?.isNewline == true { lineText.removeLast() }
        return SearchMatch(path: path, line: lineNumber, column: offsets.first?.lowerBound ?? 0,
                           text: text, ranges: ranges, lineText: String(lineText))
    }

    /// A ripgrep text field: `{"text": ...}` when valid UTF-8, otherwise
    /// `{"bytes": <base64>}`, which we decode lossily.
    private static func string(_ field: Any?) -> String? {
        guard let field = field as? [String: Any] else { return nil }
        if let text = field["text"] as? String { return text }
        if let encoded = field["bytes"] as? String, let bytes = Data(base64Encoded: encoded) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    /// The text to show for a line and where the matches fall in it.
    /// `matches` are UTF-8 byte ranges into `fullLine`, as ripgrep reports them.
    private static func display(_ fullLine: String, matches: [Range<Int>]) -> (String, [Range<Int>]) {
        var line = Substring(fullLine)
        // "\r\n" is a single Character, so a bare "\n" check would miss CRLF.
        if let last = line.last, last.isNewline { line = line.dropLast() }
        let body = line.drop { $0.isWhitespace }
        let trimmed = line.utf8.distance(from: line.startIndex, to: body.startIndex)

        // Byte offsets to indices in `body`, clipping what fell in the trimmed whitespace.
        let bodyBytes = body.utf8.count
        let spans: [Range<String.Index>] = matches.compactMap {
            let start = min(max($0.lowerBound - trimmed, 0), bodyBytes)
            let end = min(max($0.upperBound - trimmed, 0), bodyBytes)
            guard start < end else { return nil }
            return body.utf8.index(body.startIndex, offsetBy: start)..<body.utf8.index(body.startIndex, offsetBy: end)
        }

        var windowStart = body.startIndex
        var windowEnd = body.endIndex
        if body.count > maxTextLength {
            if let first = spans.first {
                windowStart = body.index(first.lowerBound, offsetBy: -leadingContext, limitedBy: body.startIndex)
                    ?? body.startIndex
            }
            let budget = maxTextLength - (windowStart > body.startIndex ? 1 : 0)
            windowEnd = body.index(windowStart, offsetBy: budget, limitedBy: body.endIndex) ?? body.endIndex
            // The trailing marker takes one of the 200.
            if windowEnd < body.endIndex { windowEnd = body.index(windowEnd, offsetBy: -1) }
        }

        let cutBefore = windowStart > body.startIndex
        let cutAfter = windowEnd < body.endIndex
        let text = (cutBefore ? "…" : "") + body[windowStart..<windowEnd] + (cutAfter ? "…" : "")
        let shift = cutBefore ? 1 : 0

        let ranges: [Range<Int>] = spans.compactMap {
            let start = max($0.lowerBound, windowStart), end = min($0.upperBound, windowEnd)
            guard start < end else { return nil }
            let from = body.utf16.distance(from: windowStart, to: start) + shift
            return from..<(from + body.utf16.distance(from: start, to: end))
        }
        return (text, ranges)
    }
}
