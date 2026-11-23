import Foundation
import Testing
@testable import ScwroteCore

/// How long a wait gives its condition before calling it a failure; each wait
/// returns as soon as its condition holds, so this only matters when something
/// is wrong (a busy 3-core CI runner can be slow).
private let patience: Duration = .seconds(30)

@MainActor
final class SettingsStoreTests {
    let folder: String
    var path: String { folder + "/settings.json" }

    init() throws {
        folder = NSTemporaryDirectory() + "scwrote settings store \(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    func put(_ text: String, at target: String? = nil) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: target ?? path))
    }

    func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func startsWithDefaultsWithoutAFile() {
        let store = SettingsStore(file: SettingsFile(path: path))
        #expect(store.settings == .defaults)
        #expect(store.problem == nil)
    }

    @Test func startsWithDefaultsAndAProblemForABrokenFile() throws {
        try put("{")
        let store = SettingsStore(file: SettingsFile(path: path))
        #expect(store.settings == .defaults)
        #expect(store.problem != nil)
    }

    @Test func setAppliesAtOnceAndWrites() {
        let store = SettingsStore(file: SettingsFile(path: path))
        #expect(store.set(.showsHiddenFilesInQuickOpen, false))
        #expect(store.settings.showsHiddenFilesInQuickOpen == false)
        #expect(store.file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: false, reopensFolders: true)))
    }

    @Test func setStillAppliesWhenTheWriteFails() throws {
        try put("{")
        let store = SettingsStore(file: SettingsFile(path: path))
        #expect(store.set(.reopensFolders, false) == false)
        #expect(store.settings.reopensFolders == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("{".utf8))
    }

    @Test func reloadKeepsLastGoodValuesWhenTheFileBreaks() throws {
        let store = SettingsStore(file: SettingsFile(path: path))
        try put(#"{"folders":{"reopen":false}}"#)
        store.reload()
        try put("{")
        store.reload()
        #expect(store.settings.reopensFolders == false)
        #expect(store.problem != nil)
    }

    @Test func reloadAfterDeleteGivesDefaults() throws {
        let store = SettingsStore(file: SettingsFile(path: path))
        try put(#"{"folders":{"reopen":false}}"#)
        store.reload()
        try FileManager.default.removeItem(atPath: path)
        store.reload()
        #expect(store.settings == .defaults)
        #expect(store.problem == nil)
    }

    @Test func handlersRunOnlyOnARealChange() throws {
        try put(#"{"folders":{"reopen":false}}"#)
        let store = SettingsStore(file: SettingsFile(path: path))
        var calls = 0
        store.onChange { _ in calls += 1 }
        store.reload()
        store.reload()
        #expect(calls == 0)
        try SettingsFile(path: path).write(.reopensFolders, true)
        store.reload()
        #expect(calls == 1)
    }

    @Test func ownWriteEchoChangesNothing() {
        let store = SettingsStore(file: SettingsFile(path: path))
        var calls = 0
        store.onChange { _ in calls += 1 }
        _ = store.set(.reopensFolders, false)
        #expect(calls == 1)
        store.reload()
        #expect(calls == 1)
    }

    @Test func watchRootIsTheFolderWhenItExists() {
        #expect(SettingsStore.watchRoot(for: "/a/b/settings.json", exists: { _ in true }) == "/a/b")
    }

    @Test func watchRootIsTheNearestExistingAncestor() {
        let root = SettingsStore.watchRoot(for: "/a/b/c/settings.json", exists: { $0 == "/a" || $0 == "/" })
        #expect(root == "/a")
    }

    @Test func aChangeByAnotherWriterIsSeen() async throws {
        let store = SettingsStore(file: SettingsFile(path: path))
        store.startWatching()
        defer { store.stopWatching() }
        try SettingsFile(path: path).write(.reopensFolders, false)
        #expect(try await eventually { store.settings.reopensFolders == false })
    }

    @Test func aFolderCreatedAfterTheWatchStartedIsPickedUp() async throws {
        let nested = folder + "/later/scwrote/settings.json"
        let store = SettingsStore(file: SettingsFile(path: nested))
        store.startWatching()
        defer { store.stopWatching() }
        try SettingsFile(path: nested).write(.reopensFolders, false)
        #expect(try await eventually { store.settings.reopensFolders == false })
        let settingsFolder = folder + "/later/scwrote"
        #expect(try await eventually { canonical(store.watchedRoot) == canonical(settingsFolder) })
        try SettingsFile(path: nested).write(.showsHiddenFilesInQuickOpen, false)
        #expect(try await eventually { store.settings.showsHiddenFilesInQuickOpen == false })
    }

    @Test func watchesThroughASymlinkedFolder() async throws {
        let real = folder + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = folder + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let store = SettingsStore(file: SettingsFile(path: link + "/settings.json"))
        store.startWatching()
        defer { store.stopWatching() }
        try SettingsFile(path: link + "/settings.json").write(.reopensFolders, false)
        #expect(try await eventually { store.settings.reopensFolders == false })
    }

    @Test func watchesThroughASymlinkedFile() async throws {
        let other = folder + "/other"
        let config = folder + "/config"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        try put("{}", at: other + "/settings.json")
        try FileManager.default.createSymbolicLink(
            atPath: config + "/settings.json", withDestinationPath: other + "/settings.json")
        let store = SettingsStore(file: SettingsFile(path: config + "/settings.json"))
        store.startWatching()
        defer { store.stopWatching() }
        #expect(canonical(store.watchedRoot) == canonical(other))
        try SettingsFile(path: config + "/settings.json").write(.reopensFolders, false)
        #expect(try await eventually { store.settings.reopensFolders == false })
        #expect(FileManager.default.destinationOfSymbolicLinkOrNil(config + "/settings.json") != nil)
    }

    @Test func aDeletedAndRecreatedFolderIsWatchedAgain() async throws {
        let sub = folder + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try put("{}", at: sub + "/settings.json")
        let store = SettingsStore(file: SettingsFile(path: sub + "/settings.json"))
        store.startWatching()
        defer { store.stopWatching() }
        try FileManager.default.removeItem(atPath: sub)
        #expect(try await eventually { canonical(store.watchedRoot) == canonical(folder) })
        try SettingsFile(path: sub + "/settings.json").write(.reopensFolders, false)
        #expect(try await eventually { store.settings.reopensFolders == false })
        #expect(try await eventually { canonical(store.watchedRoot) == canonical(sub) })
    }
}

private func canonical(_ path: String?) -> String? {
    guard let path, let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private extension FileManager {
    func destinationOfSymbolicLinkOrNil(_ path: String) -> String? {
        try? destinationOfSymbolicLink(atPath: path)
    }
}
