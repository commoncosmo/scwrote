import Foundation
import Testing
@testable import ScwroteCore

/// How long a wait in these tests gives its condition before calling it a
/// failure. Each wait returns as soon as its condition holds, so this only
/// matters when something is wrong; it is long because a busy CI runner
/// (3 cores, with nvim test processes starting alongside) can take several
/// seconds to run a shell script.
private let patience: Duration = .seconds(30)

@Suite(.enabled(if: rgPath != nil, "needs ripgrep"))
final class ProjectSearchTests {
    /// Under `NSTemporaryDirectory()`, so in its `/var/...` form, which
    /// resolves to `/private/var/...`.
    let folder: String
    /// Beside `folder`, not in it, so nothing here is in the file list.
    let tools: String

    init() throws {
        let id = UUID().uuidString
        folder = NSTemporaryDirectory() + "scwrote search \(id)"
        tools = NSTemporaryDirectory() + "scwrote search tools \(id)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.removeItem(atPath: tools)
    }

    var resolved: String { FileBrowser.realPath(folder) }

    func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: folder + "/" + name))
    }

    func makeSearch() -> ProjectSearch {
        ProjectSearch(ripgrep: rgPath!, root: folder)
    }

    /// Where `writeListRipgrep` notes each `rg --files`: "start" and "end".
    var listLog: String { tools + "/list.log" }
    /// Until this file exists, `writeListRipgrep`'s file lists don't finish.
    var listGate: String { tools + "/gate" }

    func openListGate() {
        FileManager.default.createFile(atPath: listGate, contents: nil)
    }

    /// The lines of `listLog` so far.
    var listLogLines: [String] {
        ((try? String(contentsOfFile: listLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Writes, at `path`, a ripgrep whose file list waits for `listGate`
    /// and then `delay` seconds more, so a test can act while the list is
    /// being built.
    func writeListRipgrep(at path: String, delay: Double = 0) throws {
        let script = """
            #!/bin/sh
            if [ "$1" = "--files" ]; then
              echo start >> '\(listLog)'
              while [ ! -e '\(listGate)' ]; do sleep 0.02; done
              sleep \(delay)
              '\(rgPath!)' "$@"
              status=$?
              echo end >> '\(listLog)'
              exit $status
            fi
            exec '\(rgPath!)' "$@"

            """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func makeListSearch(delay: Double = 0) throws -> ProjectSearch {
        let path = tools + "/rg"
        try writeListRipgrep(at: path, delay: delay)
        return ProjectSearch(ripgrep: path, root: folder)
    }

    /// Waits until `listLog` has `count` lines saying `word`; false after `timeout`.
    @MainActor
    func listLogShows(_ count: Int, _ word: String, within timeout: Duration = patience) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if listLogLines.filter({ $0 == word }).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// What one search delivered, and whether it finished. Main-actor only.
    @MainActor
    final class Delivery {
        var batches: [[SearchMatch]] = []
        var finishCount = 0
        private var continuation: CheckedContinuation<Bool, Never>?

        var matches: [SearchMatch] { batches.flatMap { $0 } }

        func batch(_ batch: [SearchMatch]) { batches.append(batch) }

        func finish() {
            finishCount += 1
            resume(true)
        }

        /// True once `onFinish` ran, false if it didn't within `timeout`.
        func finished(within timeout: Duration = patience) async -> Bool {
            if finishCount > 0 { return true }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    self.resume(false)
                }
            }
        }

        private func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    @MainActor
    func start(_ search: ProjectSearch, _ query: String, buffers: [UnsavedBuffer] = [],
               limit: Int? = ProjectSearch.deliveryLimit) -> Delivery {
        let delivery = Delivery()
        search.search(query, buffers: buffers, limit: limit,
                      onBatch: { delivery.batch($0) }, onFinish: { delivery.finish() })
        return delivery
    }

    /// Runs one search to the end; nil if it didn't finish within `patience`.
    @MainActor
    func results(_ search: ProjectSearch, _ query: String, buffers: [UnsavedBuffer] = [],
                 limit: Int? = ProjectSearch.deliveryLimit) async -> [SearchMatch]? {
        let delivery = start(search, query, buffers: buffers, limit: limit)
        guard await delivery.finished() else { return nil }
        return delivery.matches.sorted { $0.key < $1.key }
    }

    /// Gives any stray main-queue deliveries a chance to arrive.
    @MainActor
    func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    @Test @MainActor func findsMatchesOnDisk() async throws {
        try write("a.txt", "needle\nhay\nNeedle again\n")
        try write("b.txt", "hay\nneedle\n")
        let found = try #require(await results(makeSearch(), "needle"))
        #expect(found.map(\.key) == [
            SearchMatch.Key(path: resolved + "/a.txt", line: 1),
            SearchMatch.Key(path: resolved + "/a.txt", line: 3),
            SearchMatch.Key(path: resolved + "/b.txt", line: 2),
        ])
    }

    @Test @MainActor func bufferReplacesDiskResultsUnderASymlinkedRoot() async throws {
        #expect(folder.hasPrefix("/var/") && resolved.hasPrefix("/private/var/"))
        try write("a.txt", "needle\nhay\nhay\n")
        let buffer = UnsavedBuffer(path: FileBrowser.realPath(folder + "/a.txt"), text: "hay\nhay\nneedle")
        let found = try #require(await results(makeSearch(), "needle", buffers: [buffer]))
        #expect(found.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 3)])
    }

    @Test @MainActor func ignoredBufferIsLeftOut() async throws {
        try write(".gitignore", "skip.txt\n")
        try write("skip.txt", "hay\n")
        let buffer = UnsavedBuffer(path: resolved + "/skip.txt", text: "needle")
        let found = try #require(await results(makeSearch(), "needle", buffers: [buffer]))
        #expect(found.isEmpty)
    }

    @Test @MainActor func neverSavedBufferIsLeftOut() async throws {
        try write("a.txt", "hay\n")
        let buffer = UnsavedBuffer(path: resolved + "/new.txt", text: "needle")
        let found = try #require(await results(makeSearch(), "needle", buffers: [buffer]))
        #expect(found.isEmpty)
    }

    @Test @MainActor func staleBatchesNeverArrive() async throws {
        for index in 0..<2000 {
            try write("file \(index).txt", "a line\n")
        }
        try write("z.txt", "zzz\n")
        let search = makeSearch()
        let first = start(search, "a")
        // Holds the main queue, as a slow keystroke would, so the first
        // search's batches (and its capped finish) are queued behind it.
        usleep(500_000)
        let second = start(search, "zzz")
        #expect(await second.finished())
        await settle()
        withExtendedLifetime(search) {}
        #expect(!second.batches.isEmpty)
        for batch in second.batches {
            #expect(batch.allSatisfy { $0.text == "zzz" })
        }
        #expect(second.matches.map(\.key) == [SearchMatch.Key(path: resolved + "/z.txt", line: 1)])
        #expect(first.batches.isEmpty)
        #expect(first.finishCount == 0)
        #expect(second.finishCount == 1)
    }

    @Test @MainActor func stopsOneMatchPastTheCap() async throws {
        for index in 0..<(SearchResults.cap + 200) {
            try write("file \(index).txt", "needle\n")
        }
        let search = makeSearch()
        let delivery = start(search, "needle")
        #expect(await delivery.finished())
        await settle()
        withExtendedLifetime(search) {}
        #expect(delivery.matches.count == SearchResults.cap + 1)
        #expect(Set(delivery.matches.map(\.key)).count == SearchResults.cap + 1)
        #expect(delivery.finishCount == 1)
        var shown = SearchResults()
        delivery.batches.forEach { shown.add($0) }
        #expect(shown.isCapped)
    }

    @Test @MainActor func uncappedSearchDeliversEveryMatch() async throws {
        try write("big.txt", String(repeating: "needle\n", count: 1500))
        let found = try #require(await results(makeSearch(), "needle", limit: nil))
        #expect(found.count == 1500)
        #expect(Set(found.map(\.key)).count == 1500)
    }

    @Test @MainActor func uncappedSearchUsesUnsavedBuffers() async throws {
        try write("a.txt", "hay\nhay\nneedle on disk\nhay\n")
        let buffer = UnsavedBuffer(path: resolved + "/a.txt", text: "hay\nhay\nhay\nhay\nhay\nhay\nneedle in the buffer\n")
        let found = try #require(await results(makeSearch(), "needle", buffers: [buffer], limit: nil))
        #expect(found.map(\.line) == [7])
        #expect(found.first?.lineText == "needle in the buffer")
    }

    @Test @MainActor func fileListIsRebuiltAfterInvalidate() async throws {
        try write("a.txt", "hay\n")
        let search = makeSearch()
        let buffer = UnsavedBuffer(path: resolved + "/b.txt", text: "needle")
        #expect(try #require(await results(search, "needle", buffers: [buffer])).isEmpty)

        try write("b.txt", "hay\n")
        // The cached list doesn't have b.txt yet.
        #expect(try #require(await results(search, "needle", buffers: [buffer])).isEmpty)

        search.invalidateFileList()
        let found = try #require(await results(search, "needle", buffers: [buffer]))
        #expect(found.map(\.key) == [SearchMatch.Key(path: resolved + "/b.txt", line: 1)])
    }

    @Test @MainActor func invalidateWhileASearchWaitsForTheListStillSearchesItsBuffers() async throws {
        try write("a.txt", "hay\n")
        let search = try makeListSearch()
        let buffer = UnsavedBuffer(path: resolved + "/a.txt", text: "needle")
        let delivery = start(search, "needle", buffers: [buffer])
        #expect(await listLogShows(1, "start"))
        search.invalidateFileList()
        openListGate()
        #expect(await delivery.finished())
        #expect(delivery.matches.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 1)])
        withExtendedLifetime(search) {}
    }

    @Test @MainActor func repeatedInvalidatesDuringABuildDontStarveIt() async throws {
        try write("a.txt", "hay\n")
        openListGate()
        let search = try makeListSearch(delay: 0.3)
        let buffer = UnsavedBuffer(path: resolved + "/a.txt", text: "needle")
        let delivery = start(search, "needle", buffers: [buffer])
        // Changes every 50 ms, far more often than a build takes, as a build
        // writing into .build would.
        let churn = Task { @MainActor in
            while !Task.isCancelled {
                search.invalidateFileList()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let finished = await delivery.finished()
        churn.cancel()
        #expect(finished, "\(listLogLines)")
        #expect(delivery.matches.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 1)])
        withExtendedLifetime(search) {}
    }

    @Test @MainActor func invalidatesDuringABuildCoalesceIntoOneRebuild() async throws {
        try write("a.txt", "hay\n")
        let search = try makeListSearch()
        search.prepare()
        #expect(await listLogShows(1, "start"))
        for _ in 0..<10 { search.invalidateFileList() }
        openListGate()
        #expect(await listLogShows(2, "end"))
        await settle()
        #expect(listLogLines == ["start", "end", "start", "end"])
        withExtendedLifetime(search) {}
    }

    @Test @MainActor func prepareBuildsTheList() async throws {
        try write("a.txt", "hay\n")
        openListGate()
        let search = try makeListSearch()
        search.prepare()
        #expect(await listLogShows(1, "end"))
        let buffer = UnsavedBuffer(path: resolved + "/a.txt", text: "needle")
        let found = try #require(await results(search, "needle", buffers: [buffer]))
        #expect(found.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 1)])
        // The search used the prepared list instead of building its own.
        #expect(listLogLines == ["start", "end"])
    }

    @Test @MainActor func aListThatFailedToStartIsTriedAgain() async throws {
        try write("a.txt", "hay\n")
        let path = tools + "/rg"
        // No ripgrep there yet: every run fails to start, and the search still finishes.
        let search = ProjectSearch(ripgrep: path, root: folder)
        let buffer = UnsavedBuffer(path: resolved + "/a.txt", text: "needle")
        #expect(try #require(await results(search, "needle", buffers: [buffer])).isEmpty)

        openListGate()
        try writeListRipgrep(at: path)
        let found = try #require(await results(search, "needle", buffers: [buffer]))
        #expect(found.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 1)])
    }
}
