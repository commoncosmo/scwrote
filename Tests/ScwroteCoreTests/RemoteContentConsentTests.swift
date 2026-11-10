import Testing
@testable import ScwroteCore

struct RemoteContentConsentTests {
    @Test func nothingIsAllowedAtFirst() {
        #expect(!RemoteContentConsent().isAllowed("/n/page.html"))
    }

    @Test func allowingOneFileLeavesOthersBlocked() {
        var consent = RemoteContentConsent()
        consent.allow("/n/page.html")
        #expect(consent.isAllowed("/n/page.html"))
        #expect(!consent.isAllowed("/n/other.html"))
        #expect(!consent.isAllowed("/m/page.html"))
    }

    @Test func allowingAgainChangesNothing() {
        var consent = RemoteContentConsent()
        consent.allow("/n/a.html")
        consent.allow("/n/b.html")
        consent.allow("/n/a.html")
        #expect(consent.isAllowed("/n/a.html") && consent.isAllowed("/n/b.html"))
    }
}
