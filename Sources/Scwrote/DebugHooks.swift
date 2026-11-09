import AppKit
import ScwroteCore

/// Opt-in hooks for checking the window without a keyboard or screen access.
///
///   SCWROTE_DEBUG_KEYS="jj<CR><D-1>"   keys to press after launch, 0.4 s apart:
///       plain characters go to the browser; <CR>, <Esc>, <Up>, <Down>,
///       <Left>, <Right>, <C-d>, <C-u> are browser keys. The window's own
///       keys, <D-1> (Cmd+1), <D-S-1>, <D-[> and <D-]>, are posted as real
///       key events, so they take the path a keyboard's would.
///   SCWROTE_DEBUG_SNAPSHOT=/path.png   afterwards, save a picture of the window.
extension EditorWindowController {
    func runDebugHooks() {
        let environment = ProcessInfo.processInfo.environment
        let keys = environment["SCWROTE_DEBUG_KEYS"].map(Self.parseKeys) ?? []
        let snapshot = environment["SCWROTE_DEBUG_SNAPSHOT"]
        guard !keys.isEmpty || snapshot != nil else { return }

        Task {
            try? await Task.sleep(for: .seconds(1)) // let nvim start
            for key in keys {
                switch key {
                case let .browser(browserKey): browserView.press(browserKey)
                case let .keyboard(keyCode, characters, modifiers): post(keyCode, characters, modifiers)
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let snapshot {
                try? await Task.sleep(for: .milliseconds(600))
                saveSnapshot(to: snapshot)
            }
        }
    }

    private enum DebugKey {
        case browser(BrowserKey)
        /// A key event for the app to deliver as if typed.
        case keyboard(UInt16, String, NSEvent.ModifierFlags)
    }

    /// Posts a key press and release to the app's event queue: they go through
    /// the same key-equivalent and first-responder handling as a keyboard's.
    private func post(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func parseKeys(_ script: String) -> [DebugKey] {
        let named: [String: DebugKey] = [
            "<CR>": .browser(.enter), "<Esc>": .browser(.escape),
            "<Up>": .browser(.up), "<Down>": .browser(.down),
            "<Left>": .browser(.left), "<Right>": .browser(.right),
            "<C-d>": .browser(.halfPageDown), "<C-u>": .browser(.halfPageUp),
            "<D-1>": .keyboard(18, "1", [.command]), "<D-S-1>": .keyboard(18, "!", [.command, .shift]),
            "<D-[>": .keyboard(33, "[", [.command]), "<D-]>": .keyboard(30, "]", [.command]),
        ]
        var keys: [DebugKey] = []
        var rest = Substring(script)
        while let first = rest.first {
            if first == "<", let end = rest.firstIndex(of: ">"), let key = named[String(rest[...end])] {
                keys.append(key)
                rest = rest[rest.index(after: end)...]
            } else {
                keys.append(.browser(.character(first)))
                rest = rest.dropFirst()
            }
        }
        return keys
    }

    /// The terminal draws with Metal, so it is captured through its own
    /// snapshot API and the browser through ordinary view caching.
    private func saveSnapshot(to path: String) {
        let size = layoutView.bounds.size
        let image = NSImage(size: size)
        image.lockFocus()
        browserView.theme.background.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let terminal = terminalView.snapshotImage() {
            terminal.draw(in: layoutView.convert(terminalView.bounds, from: terminalView))
        }
        if !browserView.isHidden, let rep = browserView.bitmapImageRepForCachingDisplay(in: browserView.bounds) {
            browserView.cacheDisplay(in: browserView.bounds, to: rep)
            rep.draw(in: layoutView.convert(browserView.bounds, from: browserView))
        }
        if layoutView.mode == .split {
            browserView.theme.divider.setFill()
            NSRect(x: browserView.frame.maxX, y: 0, width: 1, height: size.height).fill()
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("scwrote: snapshot saved to \(path)\n".utf8))
    }
}
