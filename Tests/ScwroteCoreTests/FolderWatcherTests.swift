import Foundation
import Testing
@testable import ScwroteCore

/// How long a wait gives its condition before calling it a failure; each wait
/// returns as soon as its condition holds, so this only matters when something
/// is wrong (a busy 3-core CI runner can be slow).
private let patience: Duration = .seconds(30)

@MainActor
struct FolderWatcherTests {
    @Test func changeInsideTheFolderIsReported() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scwrote watcher \(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path

        var fired = false
        let watcher = FolderWatcher(path: real) { fired = true }
        defer { watcher.stop() }
        try Data("x".utf8).write(to: URL(fileURLWithPath: real + "/a.txt"))

        let deadline = ContinuousClock.now + patience
        while !fired, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fired)
    }
}
