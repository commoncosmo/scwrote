import AppKit
import ScwroteCore

/// The preview's one-row header: what is shown on the left, and on the right
/// the unsaved marker followed by the renderer's error or note.
@MainActor
final class PreviewHeaderView: NSView {
    var header = PreviewHeader(label: "No file", isUnsaved: false, message: nil, isError: false) {
        didSet { if header != oldValue { needsDisplay = true } }
    }

    private let theme: Theme
    private let sidePadding: CGFloat = 8
    private let gap: CGFloat = 12

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var lineHeight: CGFloat {
        ceil(theme.font.ascender - theme.font.descender + theme.font.leading)
    }

    /// The text sits where the browser's header row does: `topPadding` down.
    private var textTop: CGFloat { max(theme.topPadding, 4) }

    /// The row and a divider line under it.
    var preferredHeight: CGFloat { textTop * 2 + lineHeight + 1 }

    override func draw(_: NSRect) {
        theme.background.setFill()
        bounds.fill()
        theme.divider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let available = bounds.width - sidePadding * 2
        let label = attributed(header.label, color: theme.foreground)
        let status = statusText()
        // The label keeps at least 40% of the row when the status is long.
        let statusWidth = min(ceil(status.size().width), max(available - ceil(label.size().width) - gap, available * 0.6))
        if status.length > 0 {
            draw(status, x: bounds.width - sidePadding - statusWidth, width: statusWidth)
        }
        let labelWidth = available - (status.length > 0 ? statusWidth + gap : 0)
        draw(label, x: sidePadding, width: labelWidth)
    }

    /// `● unsaved`, then the message (`⚠ ` and the warning color for an error).
    private func statusText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        if header.isUnsaved {
            text.append(attributed("● unsaved", color: theme.warning))
        }
        if let message = header.message, !message.isEmpty {
            if text.length > 0 { text.append(attributed("  ", color: theme.dim)) }
            text.append(header.isError
                ? attributed("⚠ " + message, color: theme.warning)
                : attributed(message, color: theme.dim))
        }
        return text
    }

    private func attributed(_ string: String, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: theme.font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    private func draw(_ text: NSAttributedString, x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        // Taller than the glyphs: text that doesn't fit its rect isn't drawn.
        text.draw(in: NSRect(x: x, y: textTop, width: width, height: lineHeight + 2))
    }
}
