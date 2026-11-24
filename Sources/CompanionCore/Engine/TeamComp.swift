import Foundation

/// champ select team check: warnings from the champion tags and damage split of my team's picks and hovers.
public enum TeamComp {
    /// a check needs this many of the five picks known, me included.
    static let minKnown = 4

    public static func warnings(mine: DDChampion, allies: [DDChampion]) -> [String] {
        let team = [mine] + allies
        guard team.count >= minKnown else { return [] }
        var out: [String] = []
        let magic = team.filter(\.dealsMostlyMagic).count
        if magic == 0 {
            out.append("No magic damage")
        } else if magic == team.count {
            out.append("No physical damage")
        }
        if !team.contains(where: { $0.tags.contains("Tank") || $0.tags.contains("Fighter") }) {
            out.append("No frontline")
        }
        return out
    }
}

/// my results on the picked champion and into the lane opponent, from the stored games.
public struct PersonalRecord: Sendable, Equatable {
    public struct Tally: Sendable, Equatable {
        public var wins = 0
        public var games = 0
        public init(wins: Int = 0, games: Int = 0) { self.wins = wins; self.games = games }
        public var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }
    }

    public var champion: Tally
    public var matchup: Tally

    public init(champion: Tally, matchup: Tally) { self.champion = champion; self.matchup = matchup }

    /// `championID` is the data dragon id; the opponent is matched by name and only when both lanes are known.
    public static func compute(records: [GameRecord], championID: String, opponent: String?) -> PersonalRecord {
        var champion = Tally(), matchup = Tally()
        for record in records where !record.isVoid && record.champion.caseInsensitiveCompare(championID) == .orderedSame {
            guard let win = record.win else { continue }
            champion.games += 1
            if win { champion.wins += 1 }
            guard let opponent, let people = record.context?.participants,
                  let me = people.first(where: \.isMe), let lane = me.position, !lane.isEmpty,
                  people.contains(where: {
                      !$0.isAlly && !$0.isMe && $0.matches(opponent) && $0.position?.caseInsensitiveCompare(lane) == .orderedSame
                  }) else { continue }
            matchup.games += 1
            if win { matchup.wins += 1 }
        }
        return PersonalRecord(champion: champion, matchup: matchup)
    }
}
