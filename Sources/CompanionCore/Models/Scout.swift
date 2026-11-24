import Foundation

/// solo/duo rank of one player this season. memory only.
public struct ScoutRank: Sendable, Equatable {
    public var tier: String?
    public var division: String?
    public var lp: Int
    public var wins: Int
    public var losses: Int

    public init(tier: String? = nil, division: String? = nil, lp: Int = 0, wins: Int = 0, losses: Int = 0) {
        self.tier = tier; self.division = division; self.lp = lp; self.wins = wins; self.losses = losses
    }

    public static let unranked = ScoutRank()

    public var isRanked: Bool { tier != nil }
    public var games: Int { wins + losses }
    /// whole percent, nil without games.
    public var winRatePercent: Int? {
        games > 0 ? Int((Double(wins) / Double(games) * 100).rounded()) : nil
    }

    /// "Gold II · 45 LP", "Master · 312 LP" or "Unranked".
    public var label: String {
        guard let tier else { return "Unranked" }
        let name = tier.prefix(1).uppercased() + tier.dropFirst().lowercased()
        let rank = division.map { "\(name) \($0)" } ?? name
        return "\(rank) · \(lp) LP"
    }
}

/// one player of the running game. identity lives in memory only: never encodable, never logged.
public struct ScoutPlayer: Sendable, Equatable, Identifiable {
    public var id: String
    public var championKey: Int
    public var gameName: String
    public var tagLine: String
    public var puuid: String?
    public var position: String?
    public var isMe: Bool
    /// nil while unknown (not fetched yet or failed).
    public var rank: ScoutRank?
    /// what stands out about this player, most telling first (see `ScoutFlags`).
    public var flags: [ScoutFlag]

    public init(id: String, championKey: Int, gameName: String, tagLine: String, puuid: String? = nil,
                position: String? = nil, isMe: Bool = false, rank: ScoutRank? = nil, flags: [ScoutFlag] = []) {
        self.id = id; self.championKey = championKey; self.gameName = gameName; self.tagLine = tagLine
        self.puuid = puuid; self.position = position; self.isMe = isMe; self.rank = rank; self.flags = flags
    }

    public var riotId: String { tagLine.isEmpty ? gameName : "\(gameName)#\(tagLine)" }
    public var canLookUpPool: Bool { !gameName.isEmpty && !tagLine.isEmpty }
}

public struct ScoutTeam: Sendable, Equatable, Identifiable {
    public var title: String
    public var players: [ScoutPlayer]
    public var id: String { title }
    public init(title: String, players: [ScoutPlayer]) { self.title = title; self.players = players }
}

/// both teams of the running game, from the client's gameflow session. my team comes first.
public struct ScoutBoard: Sendable, Equatable {
    public var teams: [ScoutTeam]
    /// op.gg region code for champion pool lookups.
    public var region: String?
    public init(teams: [ScoutTeam], region: String? = nil) { self.teams = teams; self.region = region }

    public var players: [ScoutPlayer] { teams.flatMap(\.players) }
}

public struct PoolChampion: Sendable, Equatable {
    public var name: String
    public var games: Int
    public var wins: Int
    public init(name: String, games: Int, wins: Int) { self.name = name; self.games = games; self.wins = wins }
    public var winRatePercent: Int { games > 0 ? Int((Double(wins) / Double(games) * 100).rounded()) : 0 }
}

public enum ScoutPool: Sendable, Equatable {
    case loading
    case loaded([PoolChampion])
    case unavailable
}

/// what the client says about the running game: players with identity, before any rank is known.
public struct ScoutRoster: Sendable, Equatable {
    public var teams: [ScoutTeam]
    public var region: String?
    public init(teams: [ScoutTeam], region: String? = nil) { self.teams = teams; self.region = region }
}

/// local client lookups for the loading screen scout.
public protocol ScoutSource: Sendable {
    /// the roster of the running game (gameflow session); nil when it has none yet.
    func scoutRoster() async -> ScoutRoster?
    /// solo/duo rank; `.unranked` for a player without one, nil when the lookup failed.
    func scoutRank(puuid: String) async -> ScoutRank?
    /// the player's recent games, newest first; nil when the lookup failed.
    func scoutHistory(puuid: String) async -> [MatchSummary]?
}

extension ScoutSource {
    public func scoutHistory(puuid: String) async -> [MatchSummary]? { nil }
}

/// something worth knowing about a player before the game starts.
public enum ScoutFlag: Sendable, Equatable {
    /// a high win rate over few ranked games this season.
    case likelySmurf(winRate: Int, games: Int)
    /// the latest games in a row all won (or all lost).
    case streak(won: Bool, count: Int)
    /// most recent games on the champion they are playing now.
    case oneTrick(share: Int)
    /// no recent game on the champion they are playing now.
    case newOnChampion
    /// shared at least two recent games with a teammate: likely queued together.
    case duo(partnerChampionKey: Int)

    /// short chip text; a duo names its partner through `partner`.
    public func label(partner: String? = nil) -> String {
        switch self {
        case .likelySmurf(let wr, _): "Smurf? \(wr)%"
        case .streak(let won, let n): "\(n)\(won ? "W" : "L") streak"
        case .oneTrick: "One-trick"
        case .newOnChampion: "New on champ"
        case .duo: partner.map { "Duo with \($0)" } ?? "Duo"
        }
    }

    /// one line for an accessibility label or tooltip.
    public func detail(partner: String? = nil) -> String {
        switch self {
        case .likelySmurf(let wr, let games): "\(wr)% win rate over only \(games) ranked games: likely a smurf"
        case .streak(let won, let n): "\(won ? "Won" : "Lost") the last \(n) games"
        case .oneTrick(let share): "\(share)% of recent games on this champion"
        case .newOnChampion: "No recent games on this champion"
        case .duo: partner.map { "Played their last games with \($0)" } ?? "Played their last games together"
        }
    }
}

/// flags from rank and recent games. pure: no lookups.
public enum ScoutFlags {
    /// summoner's rift queues: draft, solo/duo, blind, flex, quickplay, swiftplay, clash.
    static let riftQueues: Set<Int> = [400, 420, 430, 440, 480, 490, 700]

    public static func compute(board: ScoutBoard, histories: [String: [MatchSummary]]) -> ScoutBoard {
        var out = board
        for t in out.teams.indices {
            let team = out.teams[t].players
            for p in team.indices {
                let player = team[p]
                let history = player.puuid.flatMap { histories[$0] }
                out.teams[t].players[p].flags = flags(for: player, history: history, team: team, histories: histories)
            }
        }
        return out
    }

    static func flags(for player: ScoutPlayer, history: [MatchSummary]?, team: [ScoutPlayer],
                      histories: [String: [MatchSummary]]) -> [ScoutFlag] {
        var flags: [ScoutFlag] = []
        if let rank = player.rank, rank.isRanked, (10...60).contains(rank.games), let wr = rank.winRatePercent, wr >= 65 {
            flags.append(.likelySmurf(winRate: wr, games: rank.games))
        }
        guard let history else { return flags }
        let rift = history.filter { !$0.remake && riftQueues.contains($0.queueId) }.sorted { $0.start > $1.start }
        if let first = rift.first {
            let run = rift.prefix { $0.win == first.win }.count
            if run >= 3 { flags.append(.streak(won: first.win, count: run)) }
        }
        if player.championKey > 0, rift.count >= 8 {
            let onChamp = rift.filter { $0.championKey == player.championKey }.count
            let share = Int((Double(onChamp) / Double(rift.count) * 100).rounded())
            if share >= 60 { flags.append(.oneTrick(share: share)) }
            else if onChamp == 0 { flags.append(.newOnChampion) }
        }
        // queued together: two shared games among the recent ones. you know your own duo, so not on you or them.
        if !player.isMe {
            let mine = Set(history.map(\.gameId))
            let partner = team.first { other in
                guard other.id != player.id, !other.isMe, let puuid = other.puuid, let theirs = histories[puuid] else { return false }
                return theirs.filter { mine.contains($0.gameId) }.count >= 2
            }
            if let partner { flags.append(.duo(partnerChampionKey: partner.championKey)) }
        }
        return flags
    }
}

/// a player's most played ranked champions this season (op.gg), best first. nil when the lookup failed.
public protocol ChampionPoolSource: Sendable {
    func championPool(gameName: String, tagLine: String, region: String) async -> [PoolChampion]?
}
