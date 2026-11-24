import Foundation

/// one op.gg rune page: riot perk ids (keystone first), with display names for the popover.
public struct RunePage: Codable, Sendable, Equatable {
    public var primaryStyleID: Int
    public var subStyleID: Int
    public var primaryStyleName: String
    public var subStyleName: String
    /// four ids, keystone first.
    public var primaryIDs: [Int]
    public var primaryNames: [String]
    /// two ids.
    public var secondaryIDs: [Int]
    public var secondaryNames: [String]
    /// three stat shards.
    public var shardIDs: [Int]
    public var shardNames: [String]
    public var play: Int
    public var win: Int
    public var pickRate: Double

    public init(primaryStyleID: Int, subStyleID: Int, primaryStyleName: String = "", subStyleName: String = "",
                primaryIDs: [Int], primaryNames: [String] = [], secondaryIDs: [Int], secondaryNames: [String] = [],
                shardIDs: [Int], shardNames: [String] = [], play: Int = 0, win: Int = 0, pickRate: Double = 0) {
        self.primaryStyleID = primaryStyleID
        self.subStyleID = subStyleID
        self.primaryStyleName = primaryStyleName
        self.subStyleName = subStyleName
        self.primaryIDs = primaryIDs
        self.primaryNames = primaryNames
        self.secondaryIDs = secondaryIDs
        self.secondaryNames = secondaryNames
        self.shardIDs = shardIDs
        self.shardNames = shardNames
        self.play = play
        self.win = win
        self.pickRate = pickRate
    }

    public static let styleIDs: Set<Int> = [8000, 8100, 8200, 8300, 8400]
    public static let shardPool: Set<Int> = [5001, 5002, 5003, 5005, 5007, 5008, 5010, 5011, 5013]

    public var keystoneName: String? { primaryNames.first }
    public var winRate: Double { play > 0 ? Double(win) / Double(play) : 0 }

    /// the nine ids in the order the client expects: primary, secondary, shards.
    public var perkIDs: [Int] { primaryIDs + secondaryIDs + shardIDs }

    /// 4 + 2 + 3 ids, two different known trees, no repeated rune (shards may repeat).
    /// no per-tree id prefix check: precision runes live in 9xxx and 8299 too.
    public var isValid: Bool {
        guard primaryIDs.count == 4, secondaryIDs.count == 2, shardIDs.count == 3,
              Self.styleIDs.contains(primaryStyleID), Self.styleIDs.contains(subStyleID),
              primaryStyleID != subStyleID else { return false }
        let runes = primaryIDs + secondaryIDs
        return runes.allSatisfy { $0 > 0 } && Set(runes).count == runes.count
            && shardIDs.allSatisfy { Self.shardPool.contains($0) }
    }
}

/// a champion that beats mine in my role (op.gg weak counter); `winRate` is the counter's win rate into mine.
public struct CounterPick: Codable, Sendable, Equatable {
    public var championKey: Int
    public var name: String
    public var winRate: Double
    public var play: Int

    public init(championKey: Int, name: String, winRate: Double, play: Int) {
        self.championKey = championKey
        self.name = name
        self.winRate = winRate
        self.play = play
    }
}

/// everything op.gg tells us about one champion in one role, fetched once per patch.
public struct ChampionAdvice: Codable, Sendable, Equatable {
    public var runes: RunePage?
    public var spellNames: [String]
    /// ability max order, e.g. Q, W, E.
    public var skillMax: [String]
    public var counters: [CounterPick]

    public init(runes: RunePage?, spellNames: [String] = [], skillMax: [String] = [], counters: [CounterPick] = []) {
        self.runes = runes
        self.spellNames = spellNames
        self.skillMax = skillMax
        self.counters = counters
    }
}

public struct MatchupTip: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case favored, even, unfavored }

    public var verdict: Verdict
    public var opponent: String
    public var tip: String?
    /// op.gg's most played rune page into this opponent; nil when the sample is thin.
    public var runes: RunePage?
    /// the most played three-item core into this opponent.
    public var coreItems: [String]
    public var coreItemIDs: [Int]

    public init(verdict: Verdict, opponent: String, tip: String?, runes: RunePage? = nil, coreItems: [String] = [],
                coreItemIDs: [Int] = []) {
        self.verdict = verdict
        self.opponent = opponent
        self.tip = tip
        self.runes = runes
        self.coreItems = coreItems
        self.coreItemIDs = coreItemIDs
    }

    /// below this many games the matchup page is noise: the standard page stays the only one.
    public static let minRuneGames = 150

    public var verdictText: String {
        switch verdict {
        case .favored: "Lane edge: you"
        case .even: "Even lane vs \(opponent)"
        case .unfavored: "Lane edge: \(opponent)"
        }
    }
}
