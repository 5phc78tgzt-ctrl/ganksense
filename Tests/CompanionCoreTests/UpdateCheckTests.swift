import Testing
@testable import CompanionCore

@Test func offersOnlyNewerVersions() {
    #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
    #expect(UpdateCheck.isNewer("0.2.1", than: "0.2"))
    #expect(!UpdateCheck.isNewer("0.2.0", than: "0.2"))
    #expect(!UpdateCheck.isNewer("0.1.9", than: "0.2.0"))
    #expect(!UpdateCheck.isNewer("9.9.9-beta", than: "0.2.0"))
    #expect(!UpdateCheck.isNewer("9.9.9", than: "dev"))
}
