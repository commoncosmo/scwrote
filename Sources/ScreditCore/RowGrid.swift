/// Rows of equal height stacked down from a top inset, in points: the file
/// browser lays its lines out on the same grid as the terminal's, so each
/// browser row sits level with an nvim line.
public struct RowGrid: Equatable, Sendable {
    public var top: Double
    public var rowHeight: Double

    public init(top: Double, rowHeight: Double) {
        self.top = top
        self.rowHeight = rowHeight
    }

    /// Ghostty reports its cell height in device pixels. Nil until it has
    /// measured (zero pixels) or without a screen scale.
    public static func cellHeight(pixels: UInt32, scale: Double) -> Double? {
        guard pixels > 0, scale > 0 else { return nil }
        return Double(pixels) / scale
    }

    public func rowTop(_ row: Int) -> Double {
        top + Double(row) * rowHeight
    }

    /// The row a point falls in; nil in the padding above the first row.
    public func row(atY y: Double) -> Int? {
        guard y >= top else { return nil }
        return Int((y - top) / rowHeight)
    }

    /// How many whole rows fit in a pane this tall.
    public func rowsThatFit(height: Double) -> Int {
        max(0, Int((height - top) / rowHeight))
    }
}
