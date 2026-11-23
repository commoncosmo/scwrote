import Foundation

/// The last color report nvim sent, remembered so the next launch starts with
/// those colors instead of flashing Ghostty's. One file for the whole app.
public struct LastColorsFile: Sendable {
    public let path: String

    /// `SCWROTE_LAST_COLORS` if set, else `~/Library/Application Support/scwrote/last-colors.json`.
    public init(environment: [String: String], home: String) {
        path = environment["SCWROTE_LAST_COLORS"] ?? home + "/Library/Application Support/scwrote/last-colors.json"
    }

    public init(path: String) { self.path = path }

    /// The remembered report; nil if there is none or it can't be read.
    public func load() -> NvimColors? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(NvimColors.self, from: data)
    }

    /// Replaces the file atomically (a temp file beside it, renamed over it),
    /// creating the folder. A failure is logged, not thrown: the colors are a
    /// convenience for the next launch.
    public func save(_ colors: NvimColors) {
        let folder = (path as NSString).deletingLastPathComponent
        let temp = folder + "/.last-colors-" + UUID().uuidString + ".tmp"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(colors)
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
