import Testing
@testable import ScreditCore

struct RowGridTests {
    @Test func cellHeightIsGhosttysPixelsInPoints() {
        #expect(RowGrid.cellHeight(pixels: 34, scale: 2) == 17)
        #expect(RowGrid.cellHeight(pixels: 33, scale: 2) == 16.5)
    }

    @Test func noCellHeightBeforeGhosttyHasMeasured() {
        #expect(RowGrid.cellHeight(pixels: 0, scale: 2) == nil)
        #expect(RowGrid.cellHeight(pixels: 34, scale: 0) == nil)
    }

    @Test func rowsStackFromTheTopPadding() {
        let grid = RowGrid(top: 2, rowHeight: 17)

        #expect(grid.rowTop(0) == 2)
        #expect(grid.rowTop(3) == 53)
    }

    @Test func aPointFallsInTheRowItIsDrawnIn() {
        let grid = RowGrid(top: 2, rowHeight: 17)

        #expect(grid.row(atY: 2) == 0)
        #expect(grid.row(atY: 18.9) == 0)
        #expect(grid.row(atY: 19) == 1)
    }

    @Test func thePaddingAboveTheFirstRowIsNoRow() {
        #expect(RowGrid(top: 2, rowHeight: 17).row(atY: 1) == nil)
    }

    @Test func onlyWholeRowsCountAsFitting() {
        let grid = RowGrid(top: 2, rowHeight: 17)

        #expect(grid.rowsThatFit(height: 2 + 17 * 10) == 10)
        #expect(grid.rowsThatFit(height: 2 + 17 * 10 - 1) == 9)
        #expect(grid.rowsThatFit(height: 1) == 0)
    }
}
