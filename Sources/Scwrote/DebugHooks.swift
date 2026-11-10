import AppKit
import ScwroteCore

/// Opt-in hooks for checking the window without a keyboard or screen access.
///
///   SCWROTE_DEBUG_KEYS="jj<CR><D-1>"   keys to press after launch, 0.4 s apart:
///       plain characters go to the browser; <CR>, <Esc>, <Up>, <Down>,
///       <Left>, <Right>, <C-d>, <C-u> are browser keys. The window's own
///       keys, <D-1> (Cmd+1), <D-S-1>, <D-2>, <D-[> and <D-]>, are posted as
///       real key events, so they take the path a keyboard's would; so is
///       <S-R> (Shift+R), for the preview's `R` when it has the keyboard, and
///       the browser prompt's editing keys <BS>, <Del> (forward delete), <Home>,
///       <End>, <C-a>, <C-e>, <C-w>, <C-h> and <D-v> (paste); <K-a>
///       and <K-d> post plain `a` and `d`. <R> repeats the last posted key as
///       if held down: a posted key is released only when the next key that
///       isn't <R> comes. Text in
///       braces goes to nvim with nvim_input, in nvim's key notation:
///       {ohello<Esc>} opens a line, types "hello" and leaves insert mode.
///   SCWROTE_DEBUG_SNAPSHOT=/path.png   afterwards, save a picture of the
///       window, and log which view has the keyboard.
///   SCWROTE_DEBUG_WIDTH=600            before the keys, set the window's
///       content width in points (for checking which panes give way).
extension EditorWindowController {
    func runDebugHooks() {
        let environment = ProcessInfo.processInfo.environment
        let keys = environment["SCWROTE_DEBUG_KEYS"].map(Self.parseKeys) ?? []
        let snapshot = environment["SCWROTE_DEBUG_SNAPSHOT"]
        let width = environment["SCWROTE_DEBUG_WIDTH"].flatMap(Double.init)
        guard !keys.isEmpty || snapshot != nil || width != nil else { return }

        Task {
            if let width, let window {
                window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
            }
            try? await Task.sleep(for: .seconds(1)) // let nvim start
            var held: (keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags)?
            for key in keys {
                if case .repeatLast = key {
                    if let held { post(.keyDown, held.keyCode, held.characters, held.modifiers, isARepeat: true) }
                } else if let released = held {
                    post(.keyUp, released.keyCode, released.characters, released.modifiers)
                    held = nil
                }
                switch key {
                case let .browser(browserKey): browserView.press(browserKey)
                case let .keyboard(keyCode, characters, modifiers):
                    post(.keyDown, keyCode, characters, modifiers)
                    held = (keyCode, characters, modifiers)
                case let .nvim(text): _ = try? await nvimCall { try $0.request("nvim_input", [.string(text)]) }
                case .repeatLast: break
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let held { post(.keyUp, held.keyCode, held.characters, held.modifiers) }
            if let snapshot {
                try? await Task.sleep(for: .milliseconds(600))
                await saveSnapshot(to: snapshot)
            }
        }
    }

    private enum DebugKey {
        case browser(BrowserKey)
        /// A key event for the app to deliver as if typed.
        case keyboard(UInt16, String, NSEvent.ModifierFlags)
        /// Keys for nvim, in its own notation.
        case nvim(String)
        /// The last posted key again, as a key repeat.
        case repeatLast
    }

    /// Posts a key press or release to the app's event queue: it goes through
    /// the same key-equivalent and first-responder handling as a keyboard's.
    /// If the app couldn't come to the front (started from a terminal that
    /// isn't), the queue would drop it for want of a key window, so a press
    /// goes to the window's key-equivalent handling directly, and if that
    /// doesn't take it, to the view with the keyboard (a release goes
    /// nowhere then).
    private func post(
        _ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool = false
    ) {
        guard let window, let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode
        ) else { return }
        if window.isKeyWindow {
            NSApp.postEvent(event, atStart: false)
        } else if type == .keyDown, !window.performKeyEquivalent(with: event) {
            window.firstResponder?.keyDown(with: event)
        }
    }

    private static func parseKeys(_ script: String) -> [DebugKey] {
        let named: [String: DebugKey] = [
            "<CR>": .browser(.enter), "<Esc>": .browser(.escape),
            "<Up>": .browser(.up), "<Down>": .browser(.down),
            "<Left>": .browser(.left), "<Right>": .browser(.right),
            "<C-d>": .browser(.halfPageDown), "<C-u>": .browser(.halfPageUp),
            "<D-1>": .keyboard(18, "1", [.command]), "<D-S-1>": .keyboard(18, "!", [.command, .shift]),
            "<D-2>": .keyboard(19, "2", [.command]),
            "<D-[>": .keyboard(33, "[", [.command]), "<D-]>": .keyboard(30, "]", [.command]),
            "<S-R>": .keyboard(15, "R", [.shift]),
            "<BS>": .keyboard(51, "\u{7f}", []),
            "<C-a>": .keyboard(0, "a", [.control]), "<C-e>": .keyboard(14, "e", [.control]),
            "<C-w>": .keyboard(13, "w", [.control]), "<C-h>": .keyboard(4, "h", [.control]),
            "<Del>": .keyboard(117, "\u{F728}", []), "<Home>": .keyboard(115, "\u{F729}", []),
            "<End>": .keyboard(119, "\u{F72B}", []), "<D-v>": .keyboard(9, "v", [.command]),
            "<K-a>": .keyboard(0, "a", []), "<K-d>": .keyboard(2, "d", []),
            "<R>": .repeatLast,
        ]
        var keys: [DebugKey] = []
        var rest = Substring(script)
        while let first = rest.first {
            if first == "{", let end = rest.firstIndex(of: "}") {
                keys.append(.nvim(String(rest[rest.index(after: rest.startIndex) ..< end])))
                rest = rest[rest.index(after: end)...]
            } else if first == "<", let end = rest.firstIndex(of: ">"), let key = named[String(rest[...end])] {
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
    /// snapshot API, the preview through its own (for its web views) and the
    /// browser through ordinary view caching.
    private func saveSnapshot(to path: String) async {
        let preview = previewView.isHidden ? nil : await previewView.snapshot()
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
        if let preview {
            preview.draw(in: layoutView.convert(previewView.bounds, from: previewView))
        }
        layoutView.dividerColor.setFill()
        for divider in layoutView.dividerRects { divider.fill() }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        let keyboard = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        FileHandle.standardError.write(Data("scwrote: snapshot saved to \(path) (keyboard: \(keyboard))\n".utf8))
    }
}
