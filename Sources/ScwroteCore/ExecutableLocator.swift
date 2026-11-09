import Foundation

public enum ExecutableLocator {
    /// Looks `name` up the way a shell does: the first executable file of that
    /// name in the colon-separated `searchPath`.
    public static func find(_ name: String, searchPath: String) -> String? {
        searchPath
            .split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
