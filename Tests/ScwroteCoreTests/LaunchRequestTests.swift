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

    /// `resolve` with the folders in `dirs` as the only existing directories.
    private func resolve(_ arguments: [String], cwd: String, dirs: String...) -> LaunchRequest {
        LaunchRequest.resolve(arguments: arguments, currentDirectory: cwd, isDirectory: { Set(dirs).contains($0) })
    }

    // MARK: --fresh and the files a launch names

    @Test func freshIsScwrotesOwn() {
        let request = resolve(["--fresh", "a.md"], cwd: "/p")

        #expect(!request.restoresSession)
        #expect(request.nvimArguments == ["a.md"])
        #expect(request.namedFiles == ["/p/a.md"])
    }

    @Test func freshAloneIsAFolderLaunch() {
        let request = resolve(["--fresh"], cwd: "/p")

        #expect(request.startsInBrowser)
        #expect(request.browserRoot == "/p")
        #expect(!request.restoresSession)
    }

    @Test func namedFilesAreAbsoluteAndSkipFlags() {
        #expect(resolve(["+3", "a.md", "sub/b.md"], cwd: "/p").namedFiles == ["/p/a.md", "/p/sub/b.md"])
    }

    @Test func aFolderLaunchNamesNoFiles() {
        #expect(resolve(["./"], cwd: "/p", dirs: "/p").namedFiles == [])
    }

    @Test func restoringIsTheDefault() {
        #expect(resolve(["a.md"], cwd: "/p").restoresSession)
    }

    // MARK: Layout flags leave nvim's session alone

    /// A session rebuilds nvim's windows, so a launch that asks nvim for a
    /// layout of its own (or a quickfix list, or a tag) keeps it: nvim's side
    /// is neither loaded nor saved. The window side still is.
    @Test(arguments: [
        ["-d", "a.md", "b.md"], ["-o", "a.md", "b.md"], ["-O", "a.md", "b.md"], ["-p", "a.md", "b.md"],
        ["-O3", "a.md", "b.md"], ["-o2", "a.md"], ["-p4", "a.md"], ["-d2", "a.md", "b.md"],
        ["-q", "errors.txt"], ["-qerrors.txt"], ["-t", "main"], ["-tmain"],
        ["--fresh", "-O", "a.md", "b.md"],
    ])
    func aLayoutFlagLeavesNvimsSessionAlone(arguments: [String]) {
        #expect(!resolve(arguments, cwd: "/p").managesNvimSession)
    }

    @Test func aLayoutFlagStillRestoresTheWindowSide() {
        let request = resolve(["-O", "a.md", "b.md"], cwd: "/p")

        #expect(request.restoresSession)
        #expect(request.nvimArguments == ["-O", "a.md", "b.md"])
    }

    @Test(arguments: [
        ["+3", "a.md"], ["-R", "a.md"], ["-c", "set nu", "a.md"], ["a.md", "b.md"], ["--", "-O", "a.md"],
        ["--startuptime", "log.txt", "a.md"], ["-", "a.md"],
    ])
    func otherFlagsKeepNvimsSession(arguments: [String]) {
        #expect(resolve(arguments, cwd: "/p").managesNvimSession)
    }

    @Test func aFolderLaunchKeepsNvimsSession() {
        #expect(resolve([], cwd: "/p").managesNvimSession)
        #expect(resolve(["-R", "src"], cwd: "/p", dirs: "/p/src").managesNvimSession)
    }

    /// `-qerrors.txt` names no path, so it's a folder launch, but nvim still
    /// opens the quickfix list a session would throw away.
    @Test func aFolderLaunchWithALayoutFlagLeavesNvimsSessionAlone() {
        let request = resolve(["-qerrors.txt"], cwd: "/p")

        #expect(request.startsInBrowser)
        #expect(!request.managesNvimSession)
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
