import AppKit
import ScwroteCore
import SwiftUI

/// The Settings window (Cmd+,): one per process, sized to its form, kept when
/// closed so the next Cmd+, shows the same window.
@MainActor
final class SettingsWindowController: NSWindowController {
    private var hasBeenShown = false

    init(store: SettingsStore) {
        let content = NSHostingController(rootView: SettingsForm(store: store))
        // The window follows the form's size, as the note comes and goes.
        content.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: content)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Makes the window key and brings it to the front; centered the first time.
    func show() {
        guard let window else { return }
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        window.makeKeyAndOrderFront(nil)
    }
}
