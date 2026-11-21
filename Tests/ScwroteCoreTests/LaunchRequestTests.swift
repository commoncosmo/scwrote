import Foundation
import Testing
@testable import ScwroteCore

struct LaunchRequestTests {
    /// Folders that exist, for `isDirectory`; everything else counts as a file.
    private func folders(_ paths: String...) -> (String) -> Bool {
        { Set(paths).contains($0) }
    }

    // MARK: Starting in the file browser

    @Test func noArgumentsStartsInTheBrowserOnTheCurrentFolder() {
        let request = LaunchRequest.resolve(
            arguments: [], currentDirectory: "/Users/me/notes", isDirectory: folders()
        )

        #expect(request.startsInBrowser)
        #expect(request.browserRoot == "/Users/me/notes")
        #expect(request.workingDirectory == "/Users/me/notes")
        #expect(request.nvimArguments == [])
        #expect(request.title == "notes")
    }

    @Test func folderArgumentStartsInTheBrowserAndBecomesTheWorkingDirectory() {
        let request = LaunchRequest.resolve(
            arguments: ["./source/testrepo"],
            currentDirectory: "/Users/me",
            isDirectory: folders("/Users/me/source/testrepo")
        )

        #expect(request.startsInBrowser)
        #expect(request.browserRoot == "/Users/me/source/testrepo")
        #expect(request.workingDirectory == "/Users/me/source/testrepo")
        // nvim must not get the folder, or it would open netrw in the editor.
        #expect(request.nvimArguments == [])
        #expect(request.title == "testrepo")
    }

    @Test func dotMeansTheCurrentFolder() {
        let request = LaunchRequest.resolve(
            arguments: ["./"], currentDirectory: "/Users/me/notes", isDirectory: folders("/Users/me/notes")
        )

        #expect(request.startsInBrowser)
        #expect(request.browserRoot == "/Users/me/notes")
    }

    @Test func nvimFlagsStillReachNvimWhenStartingOnAFolder() {
        let request = LaunchRequest.resolve(
            arguments: ["-R", "src"], currentDirectory: "/repo", isDirectory: folders("/repo/src")
        )

        #expect(request.startsInBrowser)
        #expect(request.nvimArguments == ["-R"])
    }

    // MARK: Starting in the editor

    @Test func fileArgumentStartsInTheEditorWithTheShellsFolder() {
        let request = LaunchRequest.resolve(
            arguments: ["./source/testrepo/README.md"],
            currentDirectory: "/Users/me",
            isDirectory: folders()
        )

        #expect(!request.startsInBrowser)
        #expect(request.browserRoot == "/Users/me")
        #expect(request.workingDirectory == "/Users/me")
        #expect(request.nvimArguments == ["./source/testrepo/README.md"])
        #expect(request.title == "README.md")
    }

    @Test func everyArgumentIsPassedThroughSoNvimFlagsStillWork() {
        let request = LaunchRequest.resolve(
            arguments: ["+42", "a.md", "b.md"], currentDirectory: "/tmp", isDirectory: folders()
        )

        #expect(!request.startsInBrowser)
        #expect(request.nvimArguments == ["+42", "a.md", "b.md"])
        #expect(request.title == "a.md")
    }

    // MARK: The command Ghostty runs

    @Test func shellCommandListensOnASocketAndSingleQuotesEveryWord() {
        let request = LaunchRequest(
            workingDirectory: "/tmp",
            nvimArguments: ["my notes.md", "it's.md"],
            title: "my notes.md",
            browserRoot: "/tmp",
            startsInBrowser: false
        )

        #expect(
            request.shellCommand(nvimPath: "/opt/homebrew/bin/nvim", listenAddress: "/tmp/s.sock")
                == #"'/opt/homebrew/bin/nvim' '--listen' '/tmp/s.sock' 'my notes.md' 'it'\''s.md'"#
        )
    }
}
