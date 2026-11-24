import Testing
@testable import CompanionCore

private func champ(_ id: String, tags: [String], attack: Int = 8, magic: Int = 3) -> DDChampion {
    DDChampion(id: id, key: id.count, name: id, tags: tags, attack: attack, magic: magic)
}

@Test func teamCheckWarnsOnlyWithFourPicksKnown() {
    let adc = champ("Jinx", tags: ["Marksman"])
    let ad = champ("Zed", tags: ["Assassin"])
    #expect(TeamComp.warnings(mine: adc, allies: [ad, ad]).isEmpty)
    #expect(TeamComp.warnings(mine: adc, allies: [ad, ad, ad]) == ["No magic damage", "No frontline"])
    let mage = champ("Ahri", tags: ["Mage"], attack: 3, magic: 8)
    let tank = champ("Malphite", tags: ["Tank"])
    #expect(TeamComp.warnings(mine: adc, allies: [mage, tank, ad]).isEmpty)
}

@Test func personalRecordCountsMatchupOnlyWhenBothLanesAreKnown() {
    func game(_ win: Bool, enemyLane: String?) -> GameRecord {
        let ctx = GameContext(participants: [
            .init(champion: "Ahri", isMe: true, isAlly: true, position: "MIDDLE"),
            .init(champion: "Zed", isAlly: false, position: enemyLane),
        ])
        return GameRecord(id: "\(win)\(enemyLane ?? "")", date: .now, champion: "Ahri", role: .mid, win: win,
                          goalResult: nil, deaths: [], durationSec: 1800, isVoid: false, context: ctx)
    }
    let records = [game(true, enemyLane: "MIDDLE"), game(false, enemyLane: "MIDDLE"), game(true, enemyLane: nil)]
    let r = PersonalRecord.compute(records: records, championID: "ahri", opponent: "Zed")
    #expect(r.champion == .init(wins: 2, games: 3))
    #expect(r.matchup == .init(wins: 1, games: 2))
}

@Test func matchupRunesNeedEnoughGames() throws {
    func json(play: Int) -> String {
        """
        {"data":{"lane_advantage_champion":"EVEN","core_items":[{"ids":[1,2,3],"ids_names":["A","B","C"]}],
        "runes":[{"primary_page_id":8200,"primary_page_name":"Sorcery","primary_rune_ids":[8992,8226,8210,8237],
        "primary_rune_names":["a","b","c","d"],"secondary_page_id":8100,"secondary_page_name":"Domination",
        "secondary_rune_ids":[8106,8139],"secondary_rune_names":["e","f"],"stat_mod_ids":[5005,5008,5001],
        "play":\(play),"win":\(play / 2),"pick_rate":0.4}]}}
        """
    }
    let tip = try #require(OPGGClient.matchupTip(fromJSON: json(play: 900), mine: "Ahri", opponent: "Zed"))
    #expect(tip.runes?.keystoneName == "a")
    #expect(tip.coreItems == ["A", "B", "C"] && tip.coreItemIDs == [1, 2, 3])
    let thin = try #require(OPGGClient.matchupTip(fromJSON: json(play: 40), mine: "Ahri", opponent: "Zed"))
    #expect(thin.runes == nil)
}

@Test func damageTypeFollowsTheKitNotDataDragonRatings() {
    // data dragon 16.23 ratings: qiyana 0/4 (physical), teemo 5/7 tagged marksman (ap), gwen 7/5 (ap).
    let qiyana = champ("Qiyana", tags: ["Assassin"], attack: 0, magic: 4)
    let teemo = champ("Teemo", tags: ["Marksman", "Mage"], attack: 5, magic: 7)
    let gwen = champ("Gwen", tags: ["Fighter"], attack: 7, magic: 5)
    #expect(!qiyana.dealsMostlyMagic && ChampionArchetype(champion: qiyana) == .assassinAD)
    #expect(ChampionArchetype(champion: teemo) == .mage)
    #expect(ChampionArchetype(champion: gwen) == .mage)
    // an ap build turns a marksman-tagged pick into a mage for the item filter.
    #expect(CounterBuildEngine.archetype(.marksman, following: .magic, champion: teemo) == .mage)
}
