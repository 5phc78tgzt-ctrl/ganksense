import Testing
@testable import CompanionCore

@Test func toleratesUnknownFields() throws {
    let json = """
    {"somethingNew": {"a": 1},
     "allPlayers":[{"championName":"Annie","team":"MARS","level":"oops","futureField":[1,2],
       "items":[{"itemID":1056,"extra":true}]}],
     "events":{"Events":[{"EventID":1,"EventName":"Weird","Surprise":1}]},
     "gameData":{"gameMode":"ARAM"}}
    """
    let s = try decodeSnapshot(json: json)
    let p = try #require(s.allPlayers.first)
    #expect(p.scores == Scores())
    #expect(p.scores.kills == 0)
    #expect(p.team == .unknown)
    #expect(p.level == 0)
    #expect(p.items.first?.itemID == 1056)
    #expect(p.items.first?.count == 1)
    #expect(s.events.first?.name == "Weird")
    #expect(s.isSummonersRift == false)
    #expect(s.activePlayer == nil)
}

@Test func trustDelegateOnlyTrustsLoopbackIP() {
    #expect(LocalTrustDelegate.shouldTrust(host: "127.0.0.1"))
    #expect(!LocalTrustDelegate.shouldTrust(host: "localhost"))
    #expect(!LocalTrustDelegate.shouldTrust(host: "example.com"))
    #expect(!LocalTrustDelegate.shouldTrust(host: "127.0.0.1.evil.com"))
}
