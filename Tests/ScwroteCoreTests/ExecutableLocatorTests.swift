import Foundation
import Testing
@testable import ScwroteCore

struct ExecutableLocatorTests {
    private func folder(withExecutable name: String?, executable: Bool = true) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scwrote-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let name {
            let file = folder.appendingPathComponent(name).path
            FileManager.default.createFile(
                atPath: file,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: executable ? 0o755 : 0o644]
            )
        }
        return folder.path
    }

    @Test func findsTheFirstMatchOnPath() throws {
        let empty = try folder(withExecutable: nil)
        let first = try folder(withExecutable: "nvim")
        let second = try folder(withExecutable: "nvim")

        let found = ExecutableLocator.find("nvim", searchPath: "\(empty):\(first):\(second)")

        #expect(found == "\(first)/nvim")
    }

    @Test func skipsFilesThatAreNotExecutable() throws {
        let notExecutable = try folder(withExecutable: "nvim", executable: false)

        #expect(ExecutableLocator.find("nvim", searchPath: notExecutable) == nil)
    }
}
