import Testing
@testable import CompanionCore

@Test func parsesLiveJinxResponse() throws {
    let text = try #require(OPGGTestSupport.extractText(OPGGFixtures.jinxResponse))
    let (headers, root) = try OPGGParser.parse(text)
    let b = try #require(OPGGClient.build(from: root, headers: headers))
    #expect(b.core == [2523, 3085, 3031])
    #expect(b.boots == 3006)
    #expect(b.starter == [1086, 2003, 2003])
    // fourth then fifth options in order, deduped, without 3031 (already core).
    #expect(b.situational == [3036, 3033, 3026, 3072, 3139])
}

@Test func ranksAramAugmentsAndSkipsUnnamed() throws {
    let text = try #require(OPGGTestSupport.extractText(OPGGFixtures.augmentsResponse))
    let (headers, root) = try OPGGParser.parse(text)
    let list = OPGGClient.augments(from: root, headers: headers)
    // best performance first; the unnamed row is dropped; capped at five.
    #expect(list.map(\.id) == [1389, 1335, 1315, 1322, 1080])
    #expect(list.first?.name == "Hand of Baron")
}

@Suite(.serialized)
struct OPGGClientTests {
    let cacheDir = OPGGTestSupport.freshCacheDir()

    @Test func clientReturnsNilOnTimeout() async {
        OPGGStubProtocol.reset(.hang)
        let client = OPGGClient(session: OPGGTestSupport.makeSession(), cacheDir: cacheDir, patch: "16.23.1", timeout: 0.3)
        let start = ContinuousClock.now
        #expect(await client.baseBuild(championID: "Jinx", role: .adc) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func clientDoesNotCacheFailures() async {
        OPGGStubProtocol.reset(.respond(status: 500, body: ""))
        let client = OPGGClient(session: OPGGTestSupport.makeSession(), cacheDir: cacheDir, patch: "16.23.1")
        _ = await client.baseBuild(championID: "Jinx", role: .adc)
        _ = await client.baseBuild(championID: "Jinx", role: .adc)
        #expect(OPGGStubProtocol.requestCount() == 2)
    }
}
