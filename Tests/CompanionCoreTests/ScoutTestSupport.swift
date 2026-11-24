// foundation only, never testing: see coordinatortestsupport.swift.
import Foundation
@testable import CompanionCore

func scoutRoster(_ json: String, me: String? = nil) -> ScoutRoster? {
    LCUClient.decodeScoutRoster(Data(json.utf8), mePuuid: me, region: "EUW")
}

func soloRank(_ json: String) -> ScoutRank? {
    LCUClient.decodeSoloRank(Data(json.utf8))
}

/// one finished game for scout flag tests; a lower id is a newer game.
func scoutGame(_ id: Int, champ: Int, win: Bool, queue: Int = 420) -> MatchSummary {
    MatchSummary(gameId: id, start: Date(timeIntervalSince1970: Double(1000 - id)), durationSec: 1800, queueId: queue,
                 win: win, championKey: champ, remake: false)
}
