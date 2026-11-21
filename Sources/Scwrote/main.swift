import AppKit

// Launched straight from the `scwrote` script (not through `open`), so this
// process inherits the shell's environment and working directory.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // A bare executable has no bundle icon, so the Dock would show the
    // generic "exec" one. Drawn from docs/icon/scwrote.svg.
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") {
        app.applicationIconImage = NSImage(contentsOf: url)
    }
    app.run()
}
