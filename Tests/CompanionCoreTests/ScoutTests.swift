import Testing
@testable import CompanionCore

@Test func parsesSoloRankAmongOtherQueues() throws {
    let rank = try #require(soloRank("""
    {"queues":[{"queueType":"RANKED_FLEX_SR","tier":"SILVER","division":"I","leaguePoints":5,"wins":3,"losses":9},
    {"queueType":"RANKED_SOLO_5x5","tier":"GOLD","division":"II","leaguePoints":45,"wins":61,"losses":52}]}
    """))
    #expect(rank.label == "Gold II · 45 LP")
    #expect(rank.winRatePercent == 54)
}

@Test func unrankedAndApexSoloRanks() throws {
    let unranked = try #require(soloRank("""
    {"queues":[{"queueType":"RANKED_SOLO_5x5","tier":"","division":"NA","leaguePoints":0,"wins":0,"losses":0}]}
    """))
    #expect(!unranked.isRanked && unranked.label == "Unranked" && unranked.winRatePercent == nil)
    // no solo entry at all is unranked too; an unknown shape is a failed lookup.
    #expect(soloRank(#"{"queues":[]}"#) == .unranked)
    #expect(soloRank(#"{"oops":1}"#) == nil)
    let apex = try #require(soloRank("""
    {"queueMap":{"RANKED_SOLO_5x5":{"queueType":"RANKED_SOLO_5x5","tier":"MASTER","division":"NA","leaguePoints":312,"wins":10,"losses":5}}}
    """))
    #expect(apex.label == "Master · 312 LP")
}

private let flowSession = """
{"phase":"InProgress","gameData":{"queue":{"gameMode":"CLASSIC"},
"teamOne":[{"championId":103,"puuid":"a","summonerName":"Mid","tagLine":"EUW","selectedPosition":"MIDDLE"},
{"championId":86,"puuid":"b","gameName":"Top","tagLine":"EUW","selectedPosition":"TOP"},
{"broken":true}],
"teamTwo":[{"championId":238,"puuid":"c","summonerName":"Foe#NA1"},{"championId":0}]}}
"""

@Test func parsesBothTeamsFromGameflowSession() throws {
    let roster = try #require(scoutRoster(flowSession, me: "c"))
    #expect(roster.teams.map(\.title) == ["Your team", "Enemy team"])
    // my team is the one holding my puuid; roles sort into lane order; fields may be missing.
    #expect(roster.teams[0].players.map(\.gameName) == ["Foe"])
    #expect(roster.teams[0].players[0].riotId == "Foe#NA1" && roster.teams[0].players[0].isMe)
    let enemies = roster.teams[1].players
    #expect(enemies.map(\.championKey) == [86, 103])
    #expect(enemies.map(\.riotId) == ["Top#EUW", "Mid#EUW"])
    // without my puuid the teams are named by side.
    #expect(scoutRoster(flowSession)?.teams.map(\.title) == ["Blue team", "Red team"])
    #expect(scoutRoster(#"{"gameData":{}}"#) == nil)
}

@Test func arenaRosterIsOneFlatList() throws {
    let roster = try #require(scoutRoster("""
    {"gameData":{"queue":{"gameMode":"CHERRY"},"teamOne":[{"championId":1,"puuid":"a"}],"teamTwo":[{"championId":2,"puuid":"b"}]}}
    """))
    #expect(roster.teams.count == 1 && roster.teams[0].players.count == 2)
}

@Test func scoutFlagsFromRankAndRecentGames() {
    let smurf = ScoutPlayer(id: "a", championKey: 1, gameName: "A", tagLine: "1", puuid: "a",
                            rank: ScoutRank(tier: "GOLD", division: "I", wins: 22, losses: 8))
    let duoPartner = ScoutPlayer(id: "b", championKey: 2, gameName: "B", tagLine: "1", puuid: "b")
    let board = ScoutBoard(teams: [ScoutTeam(title: "Enemy team", players: [smurf, duoPartner])])
    // a: newest first 4 wins on champ 1 then losses (aram ignored); b: shares games 1 and 2 with a, never on champ 2.
    let a = (1...10).map { scoutGame($0, champ: 1, win: $0 <= 4) } + [scoutGame(50, champ: 9, win: false, queue: 450)]
    let b = [scoutGame(1, champ: 5, win: true), scoutGame(2, champ: 5, win: true)] + (20...27).map { scoutGame($0, champ: 5, win: false) }
    let flagged = ScoutFlags.compute(board: board, histories: ["a": a, "b": b]).players
    #expect(flagged[0].flags == [.likelySmurf(winRate: 73, games: 30), .streak(won: true, count: 4),
                                 .oneTrick(share: 100), .duo(partnerChampionKey: 2)])
    #expect(flagged[1].flags == [.newOnChampion, .duo(partnerChampionKey: 1)])
}
