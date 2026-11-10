import Foundation

/// The file system operations the browser's add, rename and delete need.
/// A protocol so the rules in `FileActions` don't depend on the disk.
public protocol FileSystem: Sendable {
    func itemExists(at path: String) -> Bool
    func isFolder(at path: String) -> Bool
    /// Same item (e.g. a case-only rename on a case-insensitive volume).
    func isSameItem(_ a: String, _ b: String) -> Bool
    /// Makes missing parent folders; fails if the file exists.
    func createFile(at path: String) throws
    /// Makes missing parents; fails if the folder exists.
    func createFolder(at path: String) throws
    /// Makes missing parent folders of the destination.
    func moveItem(at source: String, to destination: String) throws
    func trashItem(at path: String) throws
    /// Everything inside the folder, recursively.
    func itemCount(inFolder path: String) -> Int
}

public struct LocalFileSystem: FileSystem {
    /// When set, `trashItem` moves into this folder instead of the user's
    /// Trash, so tests never touch the real one.
    private let trashFolder: String?

    /// nil: the user's Trash. Tests pass a temp folder.
    public init(trashFolder: String? = nil) {
        self.trashFolder = trashFolder
    }

    public func itemExists(at path: String) -> Bool {
        // lstat semantics: a dangling symlink is still an item.
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    public func isFolder(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isSameItem(_ a: String, _ b: String) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard
            let x = try? URL(fileURLWithPath: a).resourceValues(forKeys: keys).fileResourceIdentifier,
            let y = try? URL(fileURLWithPath: b).resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return x.isEqual(y)
    }

    public func createFile(at path: String) throws {
        try makeParents(of: path)
        // `.withoutOverwriting` fails when the file exists, so a race can't clobber it.
        try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    public func createFolder(at path: String) throws {
        if itemExists(at: path) { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func moveItem(at source: String, to destination: String) throws {
        try makeParents(of: destination)
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    public func trashItem(at path: String) throws {
        guard let trashFolder else {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return
        }
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        var target = trashFolder + "/" + name
        var n = 2
        while itemExists(at: target) {
            target = trashFolder + "/" + name + " \(n)"
            n += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
    }

    public func itemCount(inFolder path: String) -> Int {
        FileManager.default.enumerator(atPath: path)?.allObjects.count ?? 0
    }

    private func makeParents(of path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    }
}

/// A message the prompt shows when an action can't go ahead.
public struct FileActionError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct NewItem: Equatable, Sendable {
    public let path: String
    public let isFolder: Bool
}

/// The rules behind add, rename and delete in the browser: where a name may
/// point, what is refused, and what the prompts say. Works in the root's own
/// path form (no symlink resolution) so results match the browser's rows.
public struct FileActions: Sendable {
    private let root: String
    private let fileSystem: any FileSystem

    public init(root: String, fileSystem: any FileSystem) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.fileSystem = fileSystem
    }

    /// Where `a` puts a new item: the selected folder, the selected file's folder, or the root.
    public func folderForNewItem(selected: FileEntry?) -> String {
        guard let selected else { return root }
        return selected.isDirectory ? selected.path : (selected.path as NSString).deletingLastPathComponent
    }

    public func create(_ name: String, in folder: String) -> Result<NewItem, FileActionError> {
        let asTyped = Self.trimmingSlashes(name)
        let target: String
        switch resolve(name, in: folder) {
        case .failure(let error): return .failure(error)
        case .success(let path): target = path
        }
        if fileSystem.itemExists(at: target) {
            return .failure(FileActionError(message: "\(asTyped) already exists"))
        }
        let isFolder = name.hasSuffix("/")
        do {
            if isFolder {
                try fileSystem.createFolder(at: target)
            } else {
                try fileSystem.createFile(at: target)
            }
        } catch {
            return .failure(Self.describe(error))
        }
        return .success(NewItem(path: target, isFolder: isFolder))
    }

    /// The new path, or nil when the name didn't change.
    public func rename(_ path: String, to name: String) -> Result<String?, FileActionError> {
        let asTyped = Self.trimmingSlashes(name)
        let target: String
        switch resolve(name, in: (path as NSString).deletingLastPathComponent) {
        case .failure(let error): return .failure(error)
        case .success(let resolved): target = resolved
        }
        if target == path { return .success(nil) }
        guard fileSystem.itemExists(at: path) else { return .failure(Self.missing(path)) }
        let sameItem = fileSystem.isSameItem(path, target)
        if fileSystem.itemExists(at: target) && !sameItem {
            return .failure(FileActionError(message: "\(asTyped) already exists"))
        }
        do {
            if sameItem {
                // A case-only rename: the volume sees the destination as the
                // source itself, so go through a name that can't collide.
                let temporary = (path as NSString).deletingLastPathComponent + "/.scwrote-rename-" + UUID().uuidString
                try fileSystem.moveItem(at: path, to: temporary)
                try fileSystem.moveItem(at: temporary, to: target)
            } else {
                try fileSystem.moveItem(at: path, to: target)
            }
        } catch {
            return .failure(Self.describe(error))
        }
        return .success(target)
    }

    /// `hasUnsavedChanges`: the item, or anything inside it, has unsaved changes in nvim.
    public func deleteQuestion(for path: String, hasUnsavedChanges: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        let isFolder = fileSystem.isFolder(at: path)
        if hasUnsavedChanges {
            return "\(name)\(isFolder ? "/" : "") has unsaved changes. Delete anyway? (y/N)"
        }
        guard isFolder else { return "Delete \(name)? (y/N)" }
        let count = fileSystem.itemCount(inFolder: path)
        return "Delete folder \(name)/ and its \(count) \(count == 1 ? "item" : "items")? (y/N)"
    }

    public func delete(_ path: String) -> Result<Void, FileActionError> {
        guard fileSystem.itemExists(at: path) else { return .failure(Self.missing(path)) }
        do {
            try fileSystem.trashItem(at: path)
            return .success(())
        } catch {
            return .failure(Self.describe(error))
        }
    }

    // MARK: - Paths

    /// `name` relative to `folder`, with `.` and `..` resolved. Must land
    /// strictly inside the root.
    private func resolve(_ name: String, in folder: String) -> Result<String, FileActionError> {
        let trimmed = Self.trimmingSlashes(name)
        if trimmed.isEmpty { return .failure(FileActionError(message: "name can't be empty")) }
        let outside = FileActionError(message: "can't leave \((root as NSString).lastPathComponent)/")
        if name.hasPrefix("/") { return .failure(outside) }

        var parts = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        let resolved = "/" + parts.joined(separator: "/")
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(prefix), resolved != root else { return .failure(outside) }
        return .success(resolved)
    }

    private static func trimmingSlashes(_ name: String) -> String {
        var s = Substring(name)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    private static func missing(_ path: String) -> FileActionError {
        FileActionError(message: "\((path as NSString).lastPathComponent) no longer exists")
    }

    private static func describe(_ error: Error) -> FileActionError {
        let ns = error as NSError
        let denied =
            (ns.domain == NSCocoaErrorDomain
                && [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code))
        if denied { return FileActionError(message: "permission denied") }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(underlying.code)
        {
            return FileActionError(message: "permission denied")
        }
        return FileActionError(message: error.localizedDescription)
    }
}
