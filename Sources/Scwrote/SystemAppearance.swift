import AppKit

/// Whether macOS is in dark mode, and word when that changes. scwrote never
/// sets `NSApp.appearance`, so the app's effective appearance is the
/// system's, and it changes even while scwrote isn't frontmost.
@MainActor
final class SystemAppearance {
    private(set) var isDark: Bool
    private var handlers: [@MainActor (Bool) -> Void] = []
    private var observation: NSKeyValueObservation?

    init() {
        isDark = Self.readIsDark()
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            // AppKit changes the effective appearance on the main thread.
            MainActor.assumeIsolated { self?.appearanceChanged() }
        }
    }

    /// Runs `handler` with the new `isDark` each time it actually changes.
    func onChange(_ handler: @escaping @MainActor (Bool) -> Void) {
        handlers.append(handler)
    }

    private func appearanceChanged() {
        let isDark = Self.readIsDark()
        guard isDark != self.isDark else { return }
        self.isDark = isDark
        for handler in handlers { handler(isDark) }
    }

    private static func readIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
