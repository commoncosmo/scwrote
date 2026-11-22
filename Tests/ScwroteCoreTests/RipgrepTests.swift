import Foundation
import Testing
@testable import ScwroteCore

/// Outside the gated suite on purpose: CI must fail, not skip, without ripgrep.
@Test func ripgrepIsAvailableOnCI() {
    if ProcessInfo.processInfo.environment["CI"] != nil {
        #expect(rgPath != nil)
    }
}

@Suite(.enabled(if: rgPath != nil, "needs ripgrep"))
final class RipgrepTests {
    let folder: String

    init() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scwrote rg \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        folder = temp.path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    @discardableResult
    func write(_ name: String, _ contents: String, in dir: String? = nil) throws -> String {
        let path = (dir ?? folder) + "/" + name
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func matchCount(_ lines: [Data]) -> Int {
        lines.filter { String(decoding: $0, as: UTF8.self).contains("\"type\":\"match\"") }.count
    }

    func text(_ lines: [Data]) -> String {
        lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    @Test func argumentsMatchTheContract() {
        #expect(Ripgrep.searchArguments("x", stdin: false)
            == ["--json", "--no-config", "--no-require-git", "--fixed-strings", "--ignore-case", "--", "x"])
        #expect(Ripgrep.searchArguments("x", stdin: true)
            == ["--json", "--no-config", "--no-require-git", "--fixed-strings", "--ignore-case", "--", "x", "-"])
        #expect(Ripgrep.fileListArguments == ["--files", "--no-config", "--no-require-git"])
    }

    @Test func respectsGitignoreOutsideARepo() throws {
        try write(".gitignore", "skip.txt\n")
        try write("skip.txt", "needle\n")
        try write("keep.txt", "needle\n")
        let lines = try runCollecting(Ripgrep.searchArguments("needle", stdin: false), in: folder)
        let found = text(lines)
        #expect(matchCount(lines) == 1)
        #expect(found.contains("keep.txt"))
        #expect(!found.contains("skip.txt"))
        let files = try runCollecting(Ripgrep.fileListArguments, in: folder).map { String(decoding: $0, as: UTF8.self) }
        #expect(files == ["keep.txt"])
    }

    @Test func skipsBinaryAndHidden() throws {
        try Data("needle\0".utf8).write(to: URL(fileURLWithPath: folder + "/bin.dat"))
        try write(".hidden/a.txt", "needle\n")
        #expect(matchCount(try runCollecting(Ripgrep.searchArguments("needle", stdin: false), in: folder)) == 0)
    }

    @Test func queryStartingWithDashIsText() throws {
        try write("a.txt", "use --flag here\n")
        #expect(matchCount(try runCollecting(Ripgrep.searchArguments("--flag", stdin: false), in: folder)) == 1)
    }

    @Test func caseFoldsNonASCII() throws {
        try write("a.txt", "ÉCOLE\n")
        #expect(matchCount(try runCollecting(Ripgrep.searchArguments("école", stdin: false), in: folder)) == 1)
    }

    @Test func stdinSearch() throws {
        let lines = try runCollecting(
            Ripgrep.searchArguments("needle", stdin: true), in: folder, stdin: Data("a\nneedle\n".utf8))
        #expect(matchCount(lines) == 1)
        #expect(text(lines).contains("\"line_number\":2"))
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var lineCount = 0
        private var exitCount = 0
        let first = DispatchSemaphore(value: 0)
        func line() -> Int { lock.lock(); defer { lock.unlock() }; lineCount += 1; return lineCount }
        func exited() { lock.lock(); exitCount += 1; lock.unlock() }
        var snapshot: (lines: Int, exits: Int) { lock.lock(); defer { lock.unlock() }; return (lineCount, exitCount) }
    }

    @Test func cancelStopsCallbacks() throws {
        for i in 0..<2000 { try write("f\(i).txt", "needle\n") }
        let calls = Calls()
        let run = try RipgrepRun(
            executable: rgPath!, arguments: Ripgrep.searchArguments("needle", stdin: false), directory: folder,
            stdin: nil,
            onLine: { _ in if calls.line() == 1 { calls.first.signal() } },
            onExit: { calls.exited() })
        calls.first.wait()
        run.cancel()
        let atCancel = calls.snapshot
        Thread.sleep(forTimeInterval: 0.5)
        let later = calls.snapshot
        // ripgrep may already have finished by the time we cancel; what must
        // hold is that nothing is delivered once cancel() has returned.
        #expect(later.lines == atCancel.lines)
        #expect(later.exits == atCancel.exits)
    }

    @Test func noMatchesStillExits() throws {
        try write("a.txt", "nothing\n")
        #expect(matchCount(try runCollecting(Ripgrep.searchArguments("needle", stdin: false), in: folder)) == 0)
    }

    @Test func locatePrefersTheBundledCopy() throws {
        func exe(_ path: String) throws {
            try write(path, "")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder + "/" + path)
        }
        try exe("exe/rg")
        try exe("x/.build/ripgrep/rg")
        try exe("bin/rg")
        try FileManager.default.createDirectory(
            atPath: folder + "/x/.build/arm64-apple-macosx/release", withIntermediateDirectories: true)
        let path = folder + "/bin"
        #expect(Ripgrep.locate(executableDirectory: folder + "/exe", searchPath: path) == folder + "/exe/rg")
        let dev = folder + "/x/.build/arm64-apple-macosx/release"
        #expect(Ripgrep.locate(executableDirectory: dev, searchPath: path) == folder + "/x/.build/ripgrep/rg")
        #expect(Ripgrep.locate(executableDirectory: folder + "/nowhere", searchPath: path) == folder + "/bin/rg")
        #expect(Ripgrep.locate(executableDirectory: folder + "/nowhere", searchPath: folder + "/empty") == nil)
    }
}
