import CoreGraphics
import Foundation

extension PaneLayout {
    /// The part of a pane layout worth saving: the panes' modes by name, so a
    /// saved file survives a rename of the enums.
    public struct Saved: Codable, Equatable, Sendable {
        public var mode: String
        public var focus: String
        public var isPinned: Bool
        public var isPreviewShown: Bool

        public init(mode: String, focus: String, isPinned: Bool, isPreviewShown: Bool) {
            self.mode = mode
            self.focus = focus
            self.isPinned = isPinned
            self.isPreviewShown = isPreviewShown
        }
    }
}

/// What a project folder's window looked like when it was last closed.
public struct WindowState: Codable, Equatable, Sendable {
    /// Bumped when the saved shape changes incompatibly; other versions are
    /// ignored on read.
    public static let version = 1

    public var version: Int
    public var folder: String
    public var frame: CGRect
    public var panes: PaneLayout.Saved
    public var browserWidth: Double
    public var previewWidth: Double
    public var browserRoot: String
    public var expanded: [String]
    public var selected: String?

    public init(
        version: Int = WindowState.version, folder: String, frame: CGRect, panes: PaneLayout.Saved,
        browserWidth: Double, previewWidth: Double, browserRoot: String, expanded: [String], selected: String?
    ) {
        self.version = version
        self.folder = folder
        self.frame = frame
        self.panes = panes
        self.browserWidth = browserWidth
        self.previewWidth = previewWidth
        self.browserRoot = browserRoot
        self.expanded = expanded
        self.selected = selected
    }
}

/// Fits a saved window frame onto the screens there are now.
public enum WindowPlacement {
    /// The frame unchanged if it's fully inside a screen; otherwise moved onto
    /// the screen it overlaps most (the first if it overlaps none), shrunk only
    /// if it's larger than that screen. With no screens, unchanged.
    public static func fit(_ frame: CGRect, onto screens: [CGRect]) -> CGRect {
        guard let first = screens.first else { return frame }
        if screens.contains(where: { $0.contains(frame) }) { return frame }
        var best = first
        var bestArea = -1.0
        for screen in screens {
            let overlap = screen.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        let width = min(frame.width, best.width)
        let height = min(frame.height, best.height)
        let x = min(max(frame.minX, best.minX), best.maxX - width)
        let y = min(max(frame.minY, best.minY), best.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
