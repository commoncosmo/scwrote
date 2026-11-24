import Foundation

/// The last color report nvim sent, remembered so the next launch starts with
/// those colors instead of flashing Ghostty's. One report per background, in one file for the whole app.
public struct LastColorsFile: Sendable {
    public let path: String

    /// `SCWROTE_LAST_COLORS` if set, else `~/Library/Application Support/scwrote/last-colors.json`.
    public init(environment: [String: String], home: String) {
        path = environment["SCWROTE_LAST_COLORS"] ?? home + "/Library/Application Support/scwrote/last-colors.json"
    }

    public init(path: String) { self.path = path }

    /// The report remembered for `background`; nil if there is none or the
    /// file can't be read.
    public func load(for background: NvimBackground) -> NvimColors? {
        entries()?[background.rawValue]
    }

    /// The file's reports by background. A file from before, one bare report,
    /// counts as the entry for its own `background`.
    private func entries() -> [String: NvimColors]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        if let entries = try? decoder.decode([String: NvimColors].self, from: data) { return entries }
        guard let old = try? decoder.decode(NvimColors.self, from: data) else { return nil }
        return [old.background: old]
    }

    /// Sets the entry for the report's `background`, keeping the other one, and
    /// replaces the file atomically (a temp file beside it, renamed over it),
    /// creating the folder. A report with any other `background` is dropped. A failure is logged, not thrown: the colors are a
    /// convenience for the next launch.
    public func save(_ colors: NvimColors) {
        guard let background = NvimBackground(rawValue: colors.background) else { return }
        let folder = (path as NSString).deletingLastPathComponent
        let temp = folder + "/.last-colors-" + UUID().uuidString + ".tmp"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var all = entries() ?? [:]
            all = all.filter { NvimBackground(rawValue: $0.key) != nil }
            all[background.rawValue] = colors
            let data = try encoder.encode(all)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: temp))
            if rename(temp, path) != 0 {
                let code = errno
                try? FileManager.default.removeItem(atPath: temp)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            FileHandle.standardError.write(Data("scwrote: couldn't save \(path): \(error)\n".utf8))
        }
    }
}
