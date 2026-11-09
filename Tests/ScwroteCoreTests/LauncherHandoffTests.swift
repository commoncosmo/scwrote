import Testing
@testable import ScwroteCore

/// SIGUSR1 terminates a process that isn't listening for it, so scwrote may
/// only signal a launcher that asked (via SCWROTE_NOTIFY_PID) and is still its
/// parent, never whatever process happens to be its parent, like a shell.
struct LauncherHandoffTests {
    @Test func notifiesTheLauncherThatAskedWhileItIsStillTheParent() {
        #expect(LauncherHandoff.pidToNotify(environmentValue: "4242", parentPID: 4242) == 4242)
    }

    @Test func staysQuietWhenNobodyAsked() {
        #expect(LauncherHandoff.pidToNotify(environmentValue: nil, parentPID: 4242) == nil)
    }

    @Test func staysQuietWhenTheAskerIsNotTheParent() {
        // e.g. the variable leaked into a process started some other way.
        #expect(LauncherHandoff.pidToNotify(environmentValue: "4242", parentPID: 777) == nil)
    }

    @Test(arguments: ["", "abc", "-5", "0", "1"])
    func ignoresValuesThatAreNotALauncherPID(value: String) {
        // 1 is launchd, the parent of every orphaned process.
        #expect(LauncherHandoff.pidToNotify(environmentValue: value, parentPID: 1) == nil)
    }
}
