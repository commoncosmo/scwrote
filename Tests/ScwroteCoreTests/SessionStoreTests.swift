import CoreGraphics
import Foundation
import Testing

@testable import ScwroteCore

private final class Temp {
    let base = FileManager.default.temporaryDirectory.path + "/scwrote-session-" + UUID().uuidString
    init() throws { try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: base) }
    var store: SessionStore { SessionStore(environment: ["SCWROTE_SESSIONS_DIR": base + "/sessions"], home: "/h") }
    func folder(_ name: String) throws -> String {
        let p = base + "/" + name
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}

private func state(_ folder: String) -> WindowState {
    WindowState(
        version: WindowState.version, folder: folder, frame: CGRect(x: 10, y: 20, width: 800, height: 600),
        panes: .init(mode: "split", focus: "editor", isPinned: true, isPreviewShown: false),
        browserWidth: 240, previewWidth: 300, browserRoot: folder, expanded: [folder + "/a"], selected: folder + "/a/b")
}

@Suite struct SessionStoreTests {
    @Test func keyIsTheSameThroughASymlink() throws {
        let t = try Temp()
        let real = try t.folder("real")
        try FileManager.default.createSymbolicLink(atPath: t.base + "/link", withDestinationPath: real)
        #expect(t.store.folder(for: real).path == t.store.folder(for: t.base + "/link").path)
    }

    @Test func keyIsLowercaseHexSHA256OfTheRealPath() {
        let f = SessionStore(environment: ["SCWROTE_SESSIONS_DIR": "/s"], home: "/h").folder(for: "/nonexistent-x")
        #expect(f.path.hasPrefix("/s/") && f.path.count == 3 + 64)
        #expect(f.path.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) })
        #expect(f.windowState == f.path + "/window.json")
        #expect(f.nvimSession == f.path + "/session.vim")
        #expect(f.lock == f.path + "/lock")
    }

    @Test func environmentOverridesTheDirectory() {
        #expect(SessionStore(environment: ["SCWROTE_SESSIONS_DIR": "/x/s"], home: "/h").directory == "/x/s")
        #expect(SessionStore(environment: [:], home: "/h").directory == "/h/Library/Application Support/scwrote/sessions")
    }

    @Test func windowStateRoundTrips() throws {
        let t = try Temp()
        let root = try t.folder("p")
        let folder = t.store.folder(for: root)
        #expect(folder.readWindowState() == nil)
        try folder.write(state(root))
        #expect(folder.readWindowState() == state(root))
    }

    @Test func unreadableWindowStateIsIgnored() throws {
        let t = try Temp()
        let root = try t.folder("p")
        let folder = t.store.folder(for: root)
        try folder.write(state(root))
        try "{".write(toFile: folder.windowState, atomically: true, encoding: .utf8)
        #expect(folder.readWindowState() == nil)

        var old = state(root)
        old.version = 0
        try folder.write(old)
        #expect(folder.readWindowState() == nil)

        try folder.write(state("/somewhere/else"))
        #expect(folder.readWindowState() == nil)
    }

    @Test func takingIsExclusiveAcrossInstances() throws {
        let t = try Temp()
        let first = SessionLock(path: t.base + "/d/lock")
        let second = SessionLock(path: t.base + "/d/lock")
        try first.take(pid: getpid())
        #expect(throws: SessionLock.Held(pid: getpid())) { try second.take(pid: getpid() + 1) }
    }

    @Test func releasingLetsAnotherTake() throws {
        let t = try Temp()
        let first = SessionLock(path: t.base + "/lock")
        let second = SessionLock(path: t.base + "/lock")
        try first.take(pid: getpid())
        first.release()
        try second.take(pid: getpid())
    }

    @Test func aLockFileLeftBehindIsNotHeld() throws {
        let t = try Temp()
        try "99999".write(toFile: t.base + "/lock", atomically: true, encoding: .utf8)
        try SessionLock(path: t.base + "/lock").take(pid: getpid())
    }

    @Test func takingTwiceIsFine() throws {
        let t = try Temp()
        let lock = SessionLock(path: t.base + "/lock")
        try lock.take(pid: getpid())
        try lock.take(pid: getpid())
    }

    @Test func droppingTheLockReleasesIt() throws {
        let t = try Temp()
        do { try SessionLock(path: t.base + "/lock").take(pid: getpid()) }
        try SessionLock(path: t.base + "/lock").take(pid: getpid())
    }
}
