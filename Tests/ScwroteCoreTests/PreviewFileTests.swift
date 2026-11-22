import Foundation
import Testing
@testable import ScwroteCore

final class PreviewFileTests {
    let folder = NSTemporaryDirectory() + "scwrote preview \(UUID().uuidString)"

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    func write(_ name: String, _ data: Data) throws -> String {
        let path = folder + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func aNulByteInTheFirstEightKilobytesIsBinary() {
        #expect(PreviewFile.isBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A])))
        #expect(!PreviewFile.isBinary(Data("plain text\n".utf8)))
        #expect(!PreviewFile.isBinary(Data()))
        // Past the probe, a NUL doesn't count: ripgrep looks no further either.
        #expect(PreviewFile.isBinary(Data(repeating: 0x61, count: 8 * 1024 - 1) + Data([0])))
        #expect(!PreviewFile.isBinary(Data(repeating: 0x61, count: 8 * 1024) + Data([0])))
        // UTF-8 text with no NUL isn't binary, however unusual.
        #expect(!PreviewFile.isBinary(Data("Résumé 日本語 😀".utf8)))
    }

    @Test func linesDropLineBreaksAndAFinalOne() {
        #expect(PreviewFile.lines(of: "") == [])
        #expect(PreviewFile.lines(of: "a\nb\n") == ["a", "b"])
        #expect(PreviewFile.lines(of: "a\n\nb") == ["a", "", "b"])
        #expect(PreviewFile.lines(of: "a\r\nb\r\n") == ["a", "b"])
        #expect(PreviewFile.lines(of: "a\r\n\r\nb") == ["a", "", "b"])
    }

    @Test func aBinaryFileReadsAsBinaryEitherWay() throws {
        let path = try write("icon.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]))
        #expect(PreviewFile.read(path, whole: false) == .binary)
        #expect(PreviewFile.read(path, whole: true) == .binary)
        // Binary and past the whole-file limit: still binary, from its first bytes.
        let big = try write("big.bin", Data([0]) + Data(repeating: 0x61, count: 20_000))
        #expect(PreviewFile.read(big, whole: true, wholeLimit: 10_000) == .binary)
    }

    @Test func theHeadIsEnoughWithoutALine() throws {
        let text = (1...20_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let path = try write("long.txt", Data(text.utf8))
        guard case let .text(head, isWhole) = PreviewFile.read(path, whole: false, headLength: 64 * 1024) else {
            Issue.record("expected text")
            return
        }
        #expect(!isWhole && PreviewFile.read(path, whole: false).isPartial)
        #expect(!PreviewFile.read(path, whole: true).isPartial)
        #expect(head.first == "line 1" && head.count < 20_000 && head.count > 5_000)
        #expect(PreviewFile.read(path, whole: true) == .text(lines: PreviewFile.lines(of: text), isWhole: true))
    }

    @Test func aShortFileIsWholeFromItsHead() throws {
        let path = try write("short.txt", Data("a\nb\n".utf8))
        #expect(PreviewFile.read(path, whole: false) == .text(lines: ["a", "b"], isWhole: true))
        // Exactly the head's length is whole too: nothing follows it.
        let exact = try write("exact.txt", Data(repeating: 0x61, count: 100))
        #expect(PreviewFile.read(exact, whole: false, headLength: 100) == .text(lines: [Substring(String(repeating: "a", count: 100))], isWhole: true))
    }

    @Test func pastTheLimitIsTooLargeOnlyWhenTheWholeFileIsWanted() throws {
        let path = try write("big.txt", Data(repeating: 0x61, count: 20_000))
        #expect(PreviewFile.read(path, whole: true, wholeLimit: 10_000) == .tooLarge)
        #expect(PreviewFile.read(path, whole: true, wholeLimit: 20_000) != .tooLarge)
        #expect(PreviewFile.read(path, whole: false, headLength: 10_000)
            == .text(lines: [Substring(String(repeating: "a", count: 10_000))], isWhole: false))
    }

    @Test func anUnreadableFileHasNoLines() {
        #expect(PreviewFile.read(folder + "/missing.txt", whole: true) == .text(lines: [], isWhole: true))
    }
}
