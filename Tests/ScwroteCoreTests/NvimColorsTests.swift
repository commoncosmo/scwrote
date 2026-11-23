import Foundation
import Testing

@testable import ScwroteCore

private func s(_ v: String) -> MessagePackValue { .string(v) }

@Suite struct NvimColorsTests {
    @Test func decodesAFullReport() throws {
        let report: MessagePackValue = .map([
            s("background"): s("dark"),
            s("groups"): .map([
                s("Normal"): .map([s("fg"): .int(0xcccccc), s("bg"): .int(0x202020)]),
                s("Directory"): .map([s("fg"): .int(0x1188ff)]),
            ]),
        ])
        let colors = try #require(NvimColors(params: [report]))
        #expect(colors.background == "dark")
        #expect(colors.groups["Normal"] == NvimColors.Group(fg: RGBColor(rgb: 0xcccccc), bg: RGBColor(rgb: 0x202020)))
        #expect(colors.groups["Directory"] == NvimColors.Group(fg: RGBColor(rgb: 0x1188ff), bg: nil))
        #expect(colors.groups["Visual"] == nil)
    }

    @Test func decodesReverse() throws {
        let report: MessagePackValue = .map([
            s("background"): s("dark"),
            s("groups"): .map([
                s("Visual"): .map([s("fg"): .int(0xffaf00), s("bg"): .int(0x000000), s("reverse"): .bool(true)]),
                s("Normal"): .map([s("fg"): .int(0xcccccc), s("bg"): .int(0x202020)]),
            ]),
        ])
        let colors = try #require(NvimColors(params: [report]))
        #expect(colors.groups["Visual"]?.reverse == true)
        #expect(colors.groups["Visual"]?.fg == RGBColor(rgb: 0xffaf00))
        #expect(colors.groups["Normal"]?.reverse == false)
    }

    /// A `last-colors.json` saved before `reverse` existed still loads.
    @Test func jsonWithoutReverseDecodes() throws {
        let json = #"{"background":"dark","groups":{"Visual":{"bg":{"red":0.5,"green":0.5,"blue":0.5}}}}"#
        let colors = try JSONDecoder().decode(NvimColors.self, from: Data(json.utf8))
        #expect(colors.groups["Visual"]?.reverse == false)
        #expect(colors.groups["Visual"]?.bg == RGBColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    @Test func jsonRoundTripsReverse() throws {
        let colors = NvimColors(background: "dark", groups: [
            "Visual": .init(fg: RGBColor(rgb: 0xffaf00), bg: nil, reverse: true),
            "Normal": .init(fg: RGBColor(rgb: 0xcccccc), bg: RGBColor(rgb: 0x202020)),
        ])
        let data = try JSONEncoder().encode(colors)
        #expect(try JSONDecoder().decode(NvimColors.self, from: data) == colors)
    }

    @Test(arguments: [MessagePackValue.array([]), MessagePackValue.map([:])])
    func emptyGroupArrivesAsArrayOrMap(empty: MessagePackValue) throws {
        let report: MessagePackValue = .map([s("background"): s("light"), s("groups"): .map([s("Visual"): empty])])
        let colors = try #require(NvimColors(params: [report]))
        #expect(colors.groups["Visual"] == NvimColors.Group(fg: nil, bg: nil))
    }

    @Test(arguments: [MessagePackValue.array([]), MessagePackValue.map([:])])
    func emptyGroupsArrivesAsArrayOrMap(empty: MessagePackValue) throws {
        let report: MessagePackValue = .map([s("background"): s("dark"), s("groups"): empty])
        #expect(try #require(NvimColors(params: [report])).groups.isEmpty)
    }

    @Test func nonIntColorIsIgnored() throws {
        let report: MessagePackValue = .map([
            s("background"): s("dark"),
            s("groups"): .map([s("Normal"): .map([s("fg"): s("red"), s("bg"): .int(0x202020)])]),
        ])
        let colors = try #require(NvimColors(params: [report]))
        #expect(colors.groups["Normal"] == NvimColors.Group(fg: nil, bg: RGBColor(rgb: 0x202020)))
    }

    @Test func missingBackgroundIsNil() {
        #expect(NvimColors(params: [.map([s("groups"): .map([:])])]) == nil)
        #expect(NvimColors(params: [.map([s("background"): s("dark")])]) == nil)
    }

    @Test func otherShapesAreNil() {
        #expect(NvimColors(params: []) == nil)
        #expect(NvimColors(params: [.array([])]) == nil)
        #expect(NvimColors(params: [.string("x")]) == nil)
        #expect(NvimColors(params: [.map([:]), .map([:])]) == nil)
    }

    @Test func rgbFromInt() {
        let color = RGBColor(rgb: 0x14161b)
        #expect(color == RGBColor(red: Double(0x14) / 255, green: Double(0x16) / 255, blue: Double(0x1b) / 255))
    }

    @Test func darkness() {
        #expect(RGBColor(rgb: 0x101010).isDark)
        #expect(!RGBColor(rgb: 0xf0f0f0).isDark)
    }
}
