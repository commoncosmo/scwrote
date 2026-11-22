import Foundation
import Testing
@testable import ScwroteCore

struct RipgrepJSONTests {
    private func matchLine(
        path: String = #"{"text":"Sources/a.swift"}"#,
        lines: String,
        number: Int = 12,
        submatches: [(Int, Int)]
    ) -> Data {
        let subs = submatches.map { #"{"match":{"text":"x"},"start":\#($0.0),"end":\#($0.1)}"# }.joined(separator: ",")
        return Data(#"{"type":"match","data":{"path":\#(path),"lines":\#(lines),"line_number":\#(number),"absolute_offset":0,"submatches":[\#(subs)]}}"#.utf8)
    }

    @Test func parsesAMatch() {
        let line = matchLine(lines: #"{"text":"    let x = revealAll()\n"}"#, submatches: [(12, 18)])
        let match = RipgrepJSON.match(from: line, root: "/r")
        #expect(match?.path == "/r/Sources/a.swift")
        #expect(match?.line == 12)
        #expect(match?.column == 12)
        #expect(match?.text == "let x = revealAll()")
        #expect(match?.ranges == [8..<14])
        #expect(match?.key == SearchMatch.Key(path: "/r/Sources/a.swift", line: 12))
    }

    @Test func absolutePathsAreKeptAsTheyAre() {
        let line = matchLine(path: #"{"text":"/abs/a.swift"}"#, lines: #"{"text":"x\n"}"#, submatches: [(0, 1)])
        #expect(RipgrepJSON.match(from: line, root: "/r")?.path == "/abs/a.swift")
    }

    @Test func ignoresOtherMessages() {
        let others = [
            #"{"type":"begin","data":{"path":{"text":"a.swift"}}}"#,
            #"{"type":"end","data":{"path":{"text":"a.swift"},"binary_offset":null,"stats":{}}}"#,
            #"{"type":"context","data":{"path":{"text":"a.swift"},"lines":{"text":"x\n"},"line_number":1,"absolute_offset":0,"submatches":[]}}"#,
            #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1,"human":"0s"},"stats":{}}}"#,
            "not json {",
            "",
        ]
        for other in others {
            #expect(RipgrepJSON.match(from: Data(other.utf8), root: "/r") == nil)
        }
    }

    @Test func decodesBytesFields() {
        let path = Data([0x61, 0x2F, 0xFF, 0x2E, 0x74]).base64EncodedString()   // a/<invalid>.t
        let lines = Data("reveal \u{0}".utf8 + [0xFF, 0x0A]).base64EncodedString()
        let line = matchLine(path: #"{"bytes":"\#(path)"}"#, lines: #"{"bytes":"\#(lines)"}"#, submatches: [(0, 6)])
        let match = RipgrepJSON.match(from: line, root: "/r")
        #expect(match?.path == "/r/a/\u{FFFD}.t")
        #expect(match?.ranges == [0..<6])
    }

    @Test func labelReplacesPath() {
        let line = matchLine(lines: #"{"text":"x\n"}"#, submatches: [(0, 1)])
        #expect(RipgrepJSON.match(from: line, root: "/r", label: "/r/b.md")?.path == "/r/b.md")
    }

    @Test func longLineKeepsAWindowAroundTheFirstMatch() throws {
        let long = String(repeating: "a", count: 3000) + "needle" + String(repeating: "b", count: 2000)
        let line = matchLine(lines: #"{"text":"\#(long)\n"}"#, submatches: [(3000, 3006)])
        let match = try #require(RipgrepJSON.match(from: line, root: "/r"))
        #expect(match.column == 3000)
        #expect(match.text.count <= 200)
        #expect(match.text.hasPrefix("…"))
        #expect(match.text.hasSuffix("…"))
        #expect((match.text as NSString).substring(with: NSRange(match.ranges[0])) == "needle")
    }

    @Test func longLineMatchedNearTheStartOnlyCutsTheEnd() throws {
        let long = "needle" + String(repeating: "b", count: 500)
        let line = matchLine(lines: #"{"text":"\#(long)\n"}"#, submatches: [(0, 6)])
        let match = try #require(RipgrepJSON.match(from: line, root: "/r"))
        #expect(match.text.count == 200)
        #expect(!match.text.hasPrefix("…"))
        #expect(match.text.hasSuffix("…"))
        #expect(match.ranges == [0..<6])
    }

    @Test func multibyteBeforeTheMatch() throws {
        let line = matchLine(lines: #"{"text":"é😀 needle\n"}"#, submatches: [(7, 13)])
        let match = try #require(RipgrepJSON.match(from: line, root: "/r"))
        #expect(match.column == 7)
        #expect((match.text as NSString).substring(with: NSRange(match.ranges[0])) == "needle")
    }

    @Test func severalMatchesOnOneLine() throws {
        let line = matchLine(lines: #"{"text":"ab ab\n"}"#, submatches: [(0, 2), (3, 5)])
        let match = try #require(RipgrepJSON.match(from: line, root: "/r"))
        #expect(match.column == 0)
        #expect(match.ranges == [0..<2, 3..<5])
    }

    @Test func crlfLineEndingIsTrimmed() throws {
        let line = matchLine(lines: #"{"text":"  let a = b\r\n"}"#, submatches: [(6, 7)])
        let match = try #require(RipgrepJSON.match(from: line, root: "/r"))
        #expect(match.text == "let a = b")
        #expect(match.ranges == [4..<5])
    }

    @Test func keysSortByPathThenLine() {
        let keys = [
            SearchMatch.Key(path: "/b", line: 1), SearchMatch.Key(path: "/a", line: 10),
            SearchMatch.Key(path: "/a", line: 2),
        ]
        #expect(keys.sorted().map { "\($0.path):\($0.line)" } == ["/a:2", "/a:10", "/b:1"])
    }
}
