import Testing
@testable import ScwroteCore

struct PreviewKeysTests {
    @Test func vimKeysBecomeCommands() {
        var reader = PreviewKeyReader()
        #expect(reader.read(.character("j")) == .lineDown)
        #expect(reader.read(.up) == .lineUp)
        #expect(reader.read(.halfPageDown) == .halfPageDown)
        #expect(reader.read(.character("G")) == .bottom)
        #expect(reader.read(.character("l")) == .open)
        #expect(reader.read(.left) == .close)
        #expect(reader.read(.enter) == .toggle)
        #expect(reader.read(.escape) == .leave)
    }

    @Test func ggNeedsBothKeys() {
        var reader = PreviewKeyReader()
        #expect(reader.read(.character("g")) == nil)
        #expect(reader.read(.character("g")) == .top)
        #expect(reader.read(.character("g")) == nil)
        #expect(reader.read(.character("x")) == nil)
        #expect(reader.read(.character("j")) == .lineDown)
    }
}
