import Foundation
import Testing
@testable import ScwroteCore

struct QuickOpenQueryTests {
    @Test func trailingLineNumberIsSplitOff() {
        #expect(QuickOpenQuery("Theme.swift:115") == .init(name: "Theme.swift", line: 115))
    }
    @Test func colonWithoutDigitsIsPartOfTheName() {
        #expect(QuickOpenQuery("name:") == .init(name: "name:", line: nil))
    }
    @Test func lineAloneIsAnEmptyNameWithALine() {
        let query = QuickOpenQuery(":42")
        #expect(query.name == "" && query.line == 42 && query.isEmpty)
    }
    @Test func onlyTheLastColonCounts() {
        #expect(QuickOpenQuery("a:b:3") == .init(name: "a:b", line: 3))
    }
    @Test func lineZeroOpensAtOne() { #expect(QuickOpenQuery("x:0").line == 1) }
    @Test func hugeLineIsAPlainName() {
        #expect(QuickOpenQuery("x:99999999999999999999") == .init(name: "x:99999999999999999999", line: nil))
    }
    @Test func spacesOnlyIsAnEmptyName() {
        #expect(QuickOpenQuery("   ").isEmpty)
        #expect(QuickOpenQuery("  ewc ").name.trimmingCharacters(in: .whitespaces) == "ewc")
    }
}
