import Foundation
import Testing

@testable import ScwroteCore

private final class Temp {
    let base = FileManager.default.temporaryDirectory.path + "/scwrote-colors-" + UUID().uuidString
    init() throws { try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: base) }
}

private let sample = NvimColors(background: "dark", groups: [
    "Normal": .init(fg: RGBColor(rgb: 0xcccccc), bg: RGBColor(rgb: 0x202020)),
    "Visual": .init(fg: nil, bg: RGBColor(rgb: 0x445566)),
    "Directory": .init(fg: nil, bg: nil),
])

@Suite struct LastColorsFileTests {
    @Test func pathDefaultsToApplicationSupport() {
        #expect(LastColorsFile(environment: [:], home: "/h").path == "/h/Library/Application Support/scwrote/last-colors.json")
    }

    @Test func pathOverride() {
        #expect(LastColorsFile(environment: ["SCWROTE_LAST_COLORS": "/t/c.json"], home: "/h").path == "/t/c.json")
    }

    @Test func missingFileIsNone() throws {
        let temp = try Temp()
        #expect(LastColorsFile(path: temp.base + "/last-colors.json").load() == nil)
    }

    @Test func brokenLastColorsFileIsNone() throws {
        let temp = try Temp()
        let path = temp.base + "/last-colors.json"
        try "{".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(LastColorsFile(path: path).load() == nil)
    }

    @Test func lastColorsRoundTrip() throws {
        let temp = try Temp()
        let file = LastColorsFile(path: temp.base + "/new/folder/last-colors.json")
        file.save(sample)
        #expect(file.load() == sample)
    }

    @Test func savingReplacesAnEarlierReport() throws {
        let temp = try Temp()
        let file = LastColorsFile(path: temp.base + "/last-colors.json")
        file.save(sample)
        let other = NvimColors(background: "light", groups: [:])
        file.save(other)
        #expect(file.load() == other)
    }

    @Test func saveIsAtomic() throws {
        let temp = try Temp()
        let file = LastColorsFile(path: temp.base + "/last-colors.json")
        file.save(sample)
        file.save(sample)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.base) == ["last-colors.json"])
    }
}
