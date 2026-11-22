import Foundation
import Testing
@testable import ScwroteCore

@Suite(.enabled(if: rgPath != nil, "needs ripgrep"))
final class FolderFileListTests {
    /// Under `NSTemporaryDirectory()`, so in its `/var/...` form, which
    /// resolves to `/private/var/...`.
    let folder: String
    /// Beside `folder`, not in it, so nothing here is in the file list.
    let tools: String

    init() throws {
        let id = UUID().uuidString
        folder = NSTemporaryDirectory() + "scwrote files \(id)"
        tools = NSTemporaryDirectory() + "scwrote files tools \(id)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.removeItem(atPath: tools)
    }

    var resolved: String { FileBrowser.realPath(folder) }

    func write(_ name: String, _ contents: String) throws {
        let url = URL(fileURLWithPath: folder + "/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func relative(_ path: String) -> String {
        String(path.dropFirst(resolved.count + 1))
    }

    /// One value handed over from another thread.
    final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private var stored: Value?

        func put(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
            arrived.signal()
        }

        /// The value once put; nil if none arrives within `seconds`.
        func value(within seconds: Double = 5) async -> Value? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = self.arrived.wait(timeout: .now() + seconds)
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    continuation.resume(returning: self.stored)
                }
            }
        }
    }

    /// What `whenReady` hands over; nil if nothing within 5 seconds.
    func list(of files: FolderFileList) async -> Set<String>? {
        let box = Box<Set<String>>()
        files.whenReady { box.put($0) }
        return await box.value()
    }

    @Test func hiddenMeansAnyDotComponent() {
        #expect(FolderFileList.isHidden(relativePath: ".github/x.yml"))
        #expect(FolderFileList.isHidden(relativePath: "a/.env.example"))
        #expect(FolderFileList.isHidden(relativePath: ".gitignore"))
        #expect(!FolderFileList.isHidden(relativePath: "a/b.c/d"))
        #expect(!FolderFileList.isHidden(relativePath: "file.swift"))
    }

    @Test func listsHiddenFilesButNotIgnoredOnesOrGit() async throws {
        try write("a.txt", "a\n")
        try write(".hidden/b.txt", "b\n")
        try write(".gitignore", "out/\n")
        try write("out/c.txt", "c\n")
        try write(".git/config", "[core]\n")
        let files = FolderFileList(ripgrep: rgPath!, root: folder)
        #expect(files.root == resolved)
        let paths = try #require(await list(of: files))
        #expect(Set(paths.map(relative)) == ["a.txt", ".hidden/b.txt", ".gitignore"])
        #expect(paths.allSatisfy { $0.hasPrefix(resolved + "/") })
    }

    @Test func latestSurvivesInvalidateUntilTheNextBuild() async throws {
        try write("a.txt", "a\n")
        let files = FolderFileList(ripgrep: rgPath!, root: folder)
        #expect(files.latest == nil)
        let first = try #require(await list(of: files))
        #expect(first == [resolved + "/a.txt"])
        #expect(files.latest == first)

        files.invalidate()
        #expect(files.latest == first)

        try write("d.txt", "d\n")
        let built = Box<Set<String>>()
        files.onBuilt = { built.put($0) }
        files.prepare()
        let next = try #require(await built.value())
        #expect(next == [resolved + "/a.txt", resolved + "/d.txt"])
        #expect(files.latest == next)
    }

    @Test func whenReadyNeverRunsOnTheCallersStack() async throws {
        try write("a.txt", "a\n")
        let files = FolderFileList(ripgrep: rgPath!, root: folder)
        _ = try #require(await list(of: files))

        // The list is fresh now. If the body ran on whenReady's stack, it
        // would time out waiting for whenReady to return.
        let returned = DispatchSemaphore(value: 0)
        let ranAfterReturn = Box<Bool>()
        files.whenReady { _ in
            let afterReturn = returned.wait(timeout: .now() + 1) == .success
            // Takes the list's lock, so this never arrives if the body ran under it.
            _ = files.latest
            ranAfterReturn.put(afterReturn)
        }
        returned.signal()
        #expect(await ranAfterReturn.value() == true)
    }

    @Test func aFailedSpawnFeedsAnEmptyListAndRetries() async throws {
        try write("a.txt", "a\n")
        let path = tools + "/rg"
        // No ripgrep there yet, so the build can't start.
        let files = FolderFileList(ripgrep: path, root: folder)
        #expect(await list(of: files) == [])
        #expect(files.latest == nil)

        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: rgPath!)
        #expect(await list(of: files) == [resolved + "/a.txt"])
        #expect(files.latest == [resolved + "/a.txt"])
    }

    @Test @MainActor func searchStillSkipsHiddenUnsavedBuffers() async throws {
        try write("a.txt", "hay\n")
        try write(".hidden/b.txt", "hay\n")
        let files = FolderFileList(ripgrep: rgPath!, root: folder)
        let search = ProjectSearch(ripgrep: rgPath!, files: files)
        let buffers = [
            UnsavedBuffer(path: resolved + "/a.txt", text: "needle"),
            UnsavedBuffer(path: resolved + "/.hidden/b.txt", text: "needle"),
        ]
        let delivery = ProjectSearchTests.Delivery()
        search.search("needle", buffers: buffers,
                      onBatch: { delivery.batch($0) }, onFinish: { delivery.finish() })
        #expect(await delivery.finished())
        #expect(delivery.matches.map(\.key) == [SearchMatch.Key(path: resolved + "/a.txt", line: 1)])
        // The list itself has the hidden file; only search leaves it out.
        #expect(files.latest?.contains(resolved + "/.hidden/b.txt") == true)
        withExtendedLifetime(search) {}
    }
}
