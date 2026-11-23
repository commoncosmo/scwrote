import CoreGraphics
import Testing

@testable import ScwroteCore

private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

@Suite struct WindowStateTests {
    @Test func aFrameOnScreenStaysPut() {
        #expect(WindowPlacement.fit(r(100, 100, 800, 600), onto: [r(0, 0, 1440, 900)]) == r(100, 100, 800, 600))
    }

    @Test func aFrameOffAnyScreenMovesOntoTheNearest() {
        let f = WindowPlacement.fit(r(2000, 100, 800, 600), onto: [r(0, 0, 1440, 900)])
        #expect(r(0, 0, 1440, 900).contains(f) && f.size == CGSize(width: 800, height: 600))
    }

    @Test func aFrameBiggerThanTheScreenShrinks() {
        #expect(WindowPlacement.fit(r(0, 0, 2560, 1400), onto: [r(0, 0, 1440, 900)]) == r(0, 0, 1440, 900))
    }

    @Test func aFramePartlyOffMovesOntoTheScreenItOverlapsMost() {
        let screens = [r(0, 0, 1440, 900), r(1440, 0, 1440, 900)]
        let f = WindowPlacement.fit(r(1300, 100, 800, 600), onto: screens)
        #expect(screens[1].contains(f))
    }

    @Test func noScreensLeavesTheFrameAlone() {
        #expect(WindowPlacement.fit(r(5, 5, 10, 10), onto: []) == r(5, 5, 10, 10))
    }
}
