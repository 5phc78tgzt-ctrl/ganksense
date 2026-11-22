import Foundation

/// what the live client told us about a finished game, kept with its record so death causes can be (re)computed
/// at any time: improvements to `deathanalyzer` then apply to old games too. compact: only the roster and the
/// kill/objective events, no positions (the api has none).
///
/// privacy: players are identified by champion name only. summoner names / riot ids of other players are resolved
/// to their champion while the snapshot is read and never stored.
public struct GameContext: Codable, Sendable, Equatable {
    public struct Participant: Codable, Sendable, Equatable {
        public var champion: String
        public var isMe: Bool
        public var isAlly: Bool
        public var spells: [String]
        /// live client `position` ("top", "jungle", "middle", "bottom", "utility"); often empty.
        public var position: String?

        public init(champion: String, isMe: Bool = false, isAlly: Bool = false,
                    spells: [String] = [], position: String? = nil) {
            self.champion = champion; self.isMe = isMe
            self.isAlly = isAlly; self.spells = spells; self.position = position
        }

        public func matches(_ champion: String?) -> Bool {
            guard let champion else { return false }
            return self.champion.caseInsensitiveCompare(champion) == .orderedSame
        }

        public var hasSmite: Bool { spells.contains { $0.localizedCaseInsensitiveContains("smite") } }

        public var looksLikeJungler: Bool {
            guard hasSmite else { return false }
            let p = (position ?? "").uppercased()
            return p.isEmpty || p == "JUNGLE"
        }
    }

    /// a kill-feed or objective event. `killer`, `victim` and `assisters` are champion names (or the neutral
    /// markers below), never player names.
    public struct LoggedEvent: Codable, Sendable, Equatable {
        public var id: Int
        public var name: String
        public var time: Double
        public var killer: String?
        public var victim: String?
        public var assisters: [String]

        public init(id: Int, name: String, time: Double, killer: String? = nil, victim: String? = nil,
                    assisters: [String] = []) {
            self.id = id; self.name = name; self.time = time; self.killer = killer; self.victim = victim
            self.assisters = assisters
        }
    }

    public struct Spike: Codable, Sendable, Equatable {
        public var time: Double
        public var champion: String
        public var detail: String

        public init(time: Double, champion: String, detail: String) {
            self.time = time; self.champion = champion; self.detail = detail
        }
    }

    public var participants: [Participant]
    public var events: [LoggedEvent]
    public var spikes: [Spike]

    public init(participants: [Participant] = [], events: [LoggedEvent] = [], spikes: [Spike] = []) {
        self.participants = participants; self.events = events; self.spikes = spikes
    }

    static let keptEvents: Set<String> = [
        "ChampionKill", "DragonKill", "BaronKill", "HeraldKill", "HordeKill", "TurretKilled", "InhibKilled",
    ]

    public static let turretMarker = "Turret"
    public static let minionMarker = "Minions"
    public static let monsterMarker = "Monster"

    /// the champion name for a player name used in events, via the playerlist; a neutral marker for turrets,
    /// minions and jungle monsters; nil when it matches nobody (the name is then dropped, not kept).
    public static func resolve(_ raw: String?, players: [Player]) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let p = players.first(where: { $0.isSameAs(raw) }) { return p.championName }
        if let p = players.first(where: { $0.championName.caseInsensitiveCompare(raw) == .orderedSame }) { return p.championName }
        if raw.hasPrefix("Turret") { return turretMarker }
        if raw.hasPrefix("Minion") { return minionMarker }
        if raw.hasPrefix("SRU_") || raw.hasPrefix("Sru_") { return monsterMarker }
        return nil
    }

    public init?(snapshot s: LiveGameSnapshot, spikes: [Spike] = []) {
        guard let me = s.me else { return nil }
        participants = s.allPlayers.map { p in
            let position = p.position.flatMap { $0.isEmpty ? nil : $0 }
            return Participant(champion: p.championName, isMe: p == me,
                               isAlly: p.team == me.team && me.team != .unknown,
                               spells: p.summonerSpellNames, position: position)
        }
        let players = s.allPlayers
        var seen = Set<Int>()
        events = s.events.filter { Self.keptEvents.contains($0.name) && seen.insert($0.id).inserted }
            .map { e in
                LoggedEvent(id: e.id, name: e.name, time: e.time,
                            killer: Self.resolve(e.killer, players: players),
                            victim: Self.resolve(e.victim, players: players),
                            assisters: e.assisters.compactMap { Self.resolve($0, players: players) })
            }
        self.spikes = spikes
    }
}
