import AppKit

// Launched straight from the `scredit` script (not through `open`), so this
// process inherits the shell's environment and working directory.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
