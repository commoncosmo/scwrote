import Testing
@testable import ScwroteCore

struct BackgroundFollowerTests {
    @Test func ownedChangeIsApplied() {
        var follower = BackgroundFollower(launchedWith: .dark)
        #expect(follower.ownershipKnown(owned: true) == nil)
        #expect(follower.effectiveChanged(to: .light) == .light)
    }

    @Test func configOwnedIsNeverTouched() {
        var follower = BackgroundFollower(launchedWith: .dark)
        #expect(follower.ownershipKnown(owned: false) == nil)
        #expect(follower.effectiveChanged(to: .light) == nil)
        #expect(follower.effectiveChanged(to: .dark) == nil)
    }

    /// The follower never reads nvim's state, so a manual `:set background`
    /// lasts until the effective mode really changes.
    @Test func sameModeChangesNothing() {
        var follower = BackgroundFollower(launchedWith: .dark)
        _ = follower.ownershipKnown(owned: true)
        #expect(follower.effectiveChanged(to: .dark) == nil)
        #expect(follower.effectiveChanged(to: .light) == .light)
        #expect(follower.effectiveChanged(to: .light) == nil)
    }

    @Test func pendingChangeAppliesWhenOwnershipArrives() {
        var follower = BackgroundFollower(launchedWith: .dark)
        #expect(follower.effectiveChanged(to: .light) == nil)
        #expect(follower.ownershipKnown(owned: true) == .light)
    }

    @Test func pendingChangeBackToLaunchIsNothing() {
        var follower = BackgroundFollower(launchedWith: .dark)
        #expect(follower.effectiveChanged(to: .light) == nil)
        #expect(follower.effectiveChanged(to: .dark) == nil)
        #expect(follower.ownershipKnown(owned: true) == nil)
    }

    @Test func pendingChangeIsDroppedWhenConfigOwns() {
        var follower = BackgroundFollower(launchedWith: .dark)
        #expect(follower.effectiveChanged(to: .light) == nil)
        #expect(follower.ownershipKnown(owned: false) == nil)
    }

    @Test func ownershipIsDecidedOnce() {
        var follower = BackgroundFollower(launchedWith: .dark)
        _ = follower.ownershipKnown(owned: false)
        #expect(follower.ownershipKnown(owned: true) == nil)
        #expect(follower.effectiveChanged(to: .light) == nil)
    }
}
