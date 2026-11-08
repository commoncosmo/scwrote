import Foundation
import Testing
@testable import ScreditCore

struct LaunchRequestTests {
    @Test func noArgumentsOpensNvimInTheCurrentDirectory() {
        let request = LaunchRequest.resolve(arguments: [], currentDirectory: "/Users/sam/notes")

        #expect(request.workingDirectory == "/Users/sam/notes")
        #expect(request.nvimArguments == [])
        #expect(request.title == "notes")
    }

    @Test func fileArgumentIsPassedToNvimAsTyped() {
        let request = LaunchRequest.resolve(
            arguments: ["./source/testrepo/README.md"],
            currentDirectory: "/Users/sam"
        )

        #expect(request.workingDirectory == "/Users/sam")
        #expect(request.nvimArguments == ["./source/testrepo/README.md"])
        #expect(request.title == "README.md")
    }

    @Test func everyArgumentIsPassedThroughSoNvimFlagsStillWork() {
        let request = LaunchRequest.resolve(
            arguments: ["+42", "a.md", "b.md"],
            currentDirectory: "/tmp"
        )

        #expect(request.nvimArguments == ["+42", "a.md", "b.md"])
        #expect(request.title == "a.md")
    }

    @Test func shellCommandSingleQuotesEveryWord() {
        let request = LaunchRequest(
            workingDirectory: "/tmp",
            nvimArguments: ["my notes.md", "it's.md"],
            title: "my notes.md"
        )

        #expect(
            request.shellCommand(nvimPath: "/opt/homebrew/bin/nvim")
                == #"'/opt/homebrew/bin/nvim' 'my notes.md' 'it'\''s.md'"#
        )
    }
}
