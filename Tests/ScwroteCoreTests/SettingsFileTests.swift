import Foundation
import Testing

@testable import ScwroteCore

private final class Temp {
    let base = FileManager.default.temporaryDirectory.path + "/scwrote-settings-" + UUID().uuidString
    init() throws { try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: base) }
    var path: String { base + "/settings.json" }
    var file: SettingsFile { SettingsFile(path: path) }
    func put(_ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    func bytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    func json() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: try bytes()) as? [String: Any])
    }
}

@Suite struct SettingsFileTests {
    @Test func pathUsesXDGConfigHome() {
        #expect(SettingsFile(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h").path == "/x/scwrote/settings.json")
    }

    @Test func pathFallsBackToDotConfig() {
        #expect(SettingsFile(environment: [:], home: "/h").path == "/h/.config/scwrote/settings.json")
    }

    @Test func pathOverrideWins() {
        let env = ["SCWROTE_SETTINGS": "/t/s.json", "XDG_CONFIG_HOME": "/x"]
        #expect(SettingsFile(environment: env, home: "/h").path == "/t/s.json")
    }

    @Test func displayPathReplacesTheHomeFolderWithATilde() {
        #expect(SettingsFile.displayPath("/h/.config/a.json", home: "/h") == "~/.config/a.json")
        #expect(SettingsFile.displayPath("/hx/a.json", home: "/h") == "/hx/a.json")
        #expect(SettingsFile.displayPath("/o/a.json", home: "/h") == "/o/a.json")
    }

    @Test func settingKeysHavePathsAndAccessors() {
        #expect(SettingKey.showsHiddenFilesInQuickOpen.path == ["quickOpen", "showHiddenFiles"])
        #expect(SettingKey.reopensFolders.path == ["folders", "reopen"])
        var s = Settings.defaults
        #expect(s == Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: true))
        for key in SettingKey.allCases {
            key.set(false, in: &s)
            #expect(key.value(in: s) == false)
        }
        #expect(s == Settings(showsHiddenFilesInQuickOpen: false, reopensFolders: false))
    }

    @Test func missingFileIsMissing() throws {
        #expect(try Temp().file.load() == .missing)
    }

    @Test func missingKeyUsesItsDefault() throws {
        let t = try Temp()
        try t.put(#"{"folders":{"reopen":false}}"#)
        #expect(t.file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: false)))
    }

    @Test func wrongTypeUsesThatSettingsDefault() throws {
        let t = try Temp()
        try t.put(#"{"quickOpen":{"showHiddenFiles":"yes"},"folders":{"reopen":false}}"#)
        #expect(t.file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: false)))
    }

    @Test func aNumberIsNotABoolean() throws {
        let t = try Temp()
        try t.put(#"{"quickOpen":{"showHiddenFiles":0},"folders":{"reopen":0}}"#)
        #expect(t.file.load() == .loaded(.defaults))
    }

    @Test func aTopLevelArrayIsUnreadable() throws {
        let t = try Temp()
        try t.put("[]")
        guard case .unreadable(let message) = t.file.load() else { Issue.record("expected unreadable"); return }
        #expect(!message.isEmpty)
        #expect(throws: SettingsFileUnreadable.self) { try t.file.write(.reopensFolders, false) }
        #expect(try t.bytes() == Data("[]".utf8))
    }

    @Test func aFileWithACommentIsUnreadableAndNeverOverwritten() throws {
        let t = try Temp()
        let text = "{ // mine\n \"folders\": {\"reopen\": false} }"
        try t.put(text)
        guard case .unreadable(let message) = t.file.load() else { Issue.record("expected unreadable"); return }
        #expect(message.contains("line"))
        #expect(throws: SettingsFileUnreadable.self) { try t.file.write(.reopensFolders, true) }
        #expect(try t.bytes() == Data(text.utf8))
    }

    @Test func writeKeepsTheFilesPermissions() throws {
        let t = try Temp()
        try t.put("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: t.path)
        try t.file.write(.reopensFolders, false)
        let mode = try FileManager.default.attributesOfItem(atPath: t.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func writeDoesntEscapeSlashes() throws {
        let t = try Temp()
        try t.put(#"{"ai":{"server":"http://localhost:11434"}}"#)
        try t.file.write(.reopensFolders, false)
        let text = String(decoding: try t.bytes(), as: UTF8.self)
        #expect(text.contains("http://localhost:11434"))
    }

    @Test func writeThroughADanglingSymlinkCreatesTheTarget() throws {
        let t = try Temp()
        let target = t.base + "/dotfiles/settings.json"
        try FileManager.default.createSymbolicLink(atPath: t.path, withDestinationPath: "dotfiles/settings.json")
        try t.file.write(.reopensFolders, false)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path)) != nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: target))) as? [String: Any])
        #expect((json["folders"] as? [String: Any])?["reopen"] as? Bool == false)
    }

    @Test func writeCreatesTheFolderAndFile() throws {
        let t = try Temp()
        let file = SettingsFile(path: t.base + "/new/scwrote/settings.json")
        try file.write(.showsHiddenFilesInQuickOpen, false)
        #expect(file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: false, reopensFolders: true)))
    }

    @Test func writeKeepsUnknownKeysAndOtherValues() throws {
        let t = try Temp()
        try t.put(#"{"ai":{"server":"http://x"},"folders":{"reopen":false},"quickOpen":{"extra":1}}"#)
        try t.file.write(.showsHiddenFilesInQuickOpen, false)
        let json = try t.json()
        #expect((json["ai"] as? [String: Any])?["server"] as? String == "http://x")
        #expect((json["folders"] as? [String: Any])?["reopen"] as? Bool == false)
        let quick = try #require(json["quickOpen"] as? [String: Any])
        #expect(quick["extra"] as? Int == 1)
        #expect(quick["showHiddenFiles"] as? Bool == false)
    }

    @Test func aNonObjectSectionIsReplacedOnlyWhenItsSettingChanges() throws {
        let t = try Temp()
        try t.put(#"{"quickOpen":3,"folders":{"reopen":false}}"#)
        #expect(t.file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: false)))
        try t.file.write(.reopensFolders, true)
        #expect(try t.json()["quickOpen"] as? Int == 3)
        try t.file.write(.showsHiddenFilesInQuickOpen, false)
        let quick = try #require(try t.json()["quickOpen"] as? [String: Any])
        #expect(quick.count == 1 && quick["showHiddenFiles"] as? Bool == false)
    }

    @Test func twoWritersChangingDifferentKeysBothStick() throws {
        let t = try Temp()
        let a = SettingsFile(path: t.path)
        let b = SettingsFile(path: t.path)
        try a.write(.showsHiddenFilesInQuickOpen, false)
        try b.write(.reopensFolders, false)
        #expect(a.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: false, reopensFolders: false)))
    }

    @Test func writeIsAtomic() throws {
        let t = try Temp()
        try t.put("{}")
        func inode() throws -> UInt64 {
            (try FileManager.default.attributesOfItem(atPath: t.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
        let before = try inode()
        try t.file.write(.reopensFolders, false)
        #expect(try inode() != before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.base) == ["settings.json"])
    }

    @Test func writeThroughASymlinkKeepsTheLink() throws {
        let t = try Temp()
        try FileManager.default.createDirectory(atPath: t.base + "/dotfiles", withIntermediateDirectories: true)
        try #"{"folders":{"reopen":true}}"#.write(toFile: t.base + "/dotfiles/settings.json", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: t.path, withDestinationPath: "dotfiles/settings.json")
        try t.file.write(.reopensFolders, false)
        #expect(try FileManager.default.attributesOfItem(atPath: t.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        let target = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: t.base + "/dotfiles/settings.json")))
                as? [String: Any])
        #expect((target["folders"] as? [String: Any])?["reopen"] as? Bool == false)
    }

    @Test func appearanceModeDefaultsToSystem() throws {
        let t = try Temp()
        try t.put(#"{"folders":{"reopen":false}}"#)
        guard case .loaded(let settings) = t.file.load() else { Issue.record("expected loaded"); return }
        #expect(settings.appearanceMode == .system)
    }

    @Test func appearanceModeReadsEachValue() throws {
        let t = try Temp()
        for (text, mode) in [("light", AppearanceMode.light), ("dark", .dark), ("system", .system)] {
            try t.put(#"{"appearance":{"mode":"\#(text)"}}"#)
            guard case .loaded(let settings) = t.file.load() else { Issue.record("expected loaded"); return }
            #expect(settings.appearanceMode == mode)
        }
    }

    @Test func anUnknownOrWrongTypedModeIsSystem() throws {
        let t = try Temp()
        for value in [#""Light""#, "3", "null", "true", "[]"] {
            try t.put(#"{"appearance":{"mode":\#(value)},"folders":{"reopen":false}}"#)
            #expect(t.file.load() == .loaded(Settings(showsHiddenFilesInQuickOpen: true, reopensFolders: false)))
        }
    }

    @Test func writingTheModeKeepsOtherKeys() throws {
        let t = try Temp()
        try t.put(#"{"quickOpen":{"showHiddenFiles":false},"x":1}"#)
        try t.file.write(AppearanceMode.dark)
        let json = try t.json()
        #expect(json["appearance"] as? [String: String] == ["mode": "dark"])
        #expect((json["quickOpen"] as? [String: Any])?["showHiddenFiles"] as? Bool == false)
        #expect(json["x"] as? Int == 1)
    }

    @Test func writingTheModeOverAnUnreadableFileThrows() throws {
        let t = try Temp()
        try t.put("{ // c")
        #expect(throws: SettingsFileUnreadable.self) { try t.file.write(AppearanceMode.dark) }
        #expect(try t.bytes() == Data("{ // c".utf8))
    }
}

@Suite struct AppearanceModeTests {
    @Test func systemFollowsTheSystemAppearance() {
        #expect(AppearanceMode.system.background(systemIsDark: true) == .dark)
        #expect(AppearanceMode.system.background(systemIsDark: false) == .light)
    }

    @Test func lightAndDarkIgnoreTheSystem() {
        for dark in [true, false] {
            #expect(AppearanceMode.light.background(systemIsDark: dark) == .light)
            #expect(AppearanceMode.dark.background(systemIsDark: dark) == .dark)
        }
    }
}
