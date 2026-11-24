import Testing
@testable import CompanionCore

@Suite struct GoldLeadTests {
    private func snapshot(mode: String = "CLASSIC", map: Int = 11, _ players: [Player]) -> LiveGameSnapshot {
        LiveGameSnapshot(activePlayer: ActivePlayer(summonerName: "me"), allPlayers: players, events: [],
                         gameData: GameData(gameMode: mode, gameTime: 600, mapNumber: map))
    }

    @Test func sumsItemValueWithCountsAndSkipsConsumablesAndTrinkets() {
        let mine = goldPlayer(.order, "MIDDLE", items: [
            PlayerItem(itemID: 1), PlayerItem(itemID: 2, count: 2), PlayerItem(itemID: 3, count: 5),
            PlayerItem(itemID: 4, slot: 6)], name: "me")
        let enemy = goldPlayer(.chaos, "MIDDLE", items: [PlayerItem(itemID: 1)], name: "foe")
        let lead = GoldLead.compute(snapshot: snapshot([mine, enemy]), catalog: goldCatalog())
        #expect(lead?.team == 2000)
        #expect(lead?.lane == 2000)
    }

    @Test func laneNeedsExactlyOneOpponentWithMyPosition() {
        let me = goldPlayer(.order, "TOP", items: [PlayerItem(itemID: 1)], name: "me")
        let a = goldPlayer(.chaos, "TOP", items: [PlayerItem(itemID: 2)], name: "a")
        let b = goldPlayer(.chaos, "TOP", items: [], name: "b")
        #expect(GoldLead.compute(snapshot: snapshot([me, a, b]), catalog: goldCatalog())?.lane == nil)
        let unknown = goldPlayer(.order, nil, items: [PlayerItem(itemID: 1)], name: "me")
        #expect(GoldLead.compute(snapshot: snapshot([unknown, a]), catalog: goldCatalog())?.lane == nil)
        #expect(GoldLead.compute(snapshot: snapshot([me, a]), catalog: goldCatalog())?.lane == 2000)
    }

    @Test func aramHasTeamLeadOnlyAndOtherMapsNone() {
        let me = goldPlayer(.order, "TOP", items: [PlayerItem(itemID: 1)], name: "me")
        let foe = goldPlayer(.chaos, "TOP", items: [], name: "foe")
        let aram = GoldLead.compute(snapshot: snapshot(mode: "ARAM", map: 12, [me, foe]), catalog: goldCatalog())
        #expect(aram?.team == 3000)
        #expect(aram?.lane == nil && aram?.roles.isEmpty == true)
        #expect(GoldLead.compute(snapshot: snapshot(mode: "CHERRY", map: 30, [me, foe]), catalog: goldCatalog()) == nil)
    }
}
