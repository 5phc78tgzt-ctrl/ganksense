@testable import CompanionCore

/// minimal snapshot: me (jinx, order), one ally with the given kills, one enemy.
func goalSnapshot(time: Double, cs: Int = 0, kills: Int = 0, assists: Int = 0, deaths: Int = 0,
                  allyKills: Int = 0, gold: Double = 0, items: [PlayerItem] = [],
                  events: [GameEvent] = []) -> LiveGameSnapshot {
    let me = Player(championName: "Jinx", team: .order, items: items,
                    scores: Scores(kills: kills, deaths: deaths, assists: assists, creepScore: cs),
                    summonerName: "poopdog#swag")
    let ally = Player(championName: "Garen", team: .order, scores: Scores(kills: allyKills), summonerName: "Ally#1")
    let enemy = Player(championName: "Zed", team: .chaos, summonerName: "Foe#1")
    return LiveGameSnapshot(activePlayer: ActivePlayer(summonerName: "poopdog#swag", currentGold: gold),
                            allPlayers: [me, ally, enemy], events: events,
                            gameData: GameData(gameMode: "CLASSIC", gameTime: time, mapNumber: 11))
}
