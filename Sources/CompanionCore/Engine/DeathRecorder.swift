public struct DeathEvent: Codable, Sendable, Equatable, Identifiable {
    /// live client `eventid`; stable across polls and reconnects, so it is the dedup key.
    public var id: Int
    public var time: Double
    public var killer: String?
    public var assisters: [String]

    public init(id: Int, time: Double, killer: String? = nil, assisters: [String] = []) {
        self.id = id; self.time = time; self.killer = killer; self.assisters = assisters
    }
}

public enum DeathRecorder {
    /// every `championkill` whose victim is me, deduplicated by eventid, ordered by time. killer and assisters are
    /// stored as champion names (other players' riot ids are never kept); a killer that matches nobody on the
    /// playerlist is nil. empty while "me" cannot be identified (loading screen / partial data).
    public static func deaths(in snapshot: LiveGameSnapshot) -> [DeathEvent] {
        guard let me = snapshot.me else { return [] }
        var seen = Set<Int>()
        var out: [DeathEvent] = []
        for e in snapshot.events where e.name == "ChampionKill" && me.isSameAs(e.victim) {
            guard seen.insert(e.id).inserted else { continue }
            let players = snapshot.allPlayers
            out.append(DeathEvent(id: e.id, time: e.time,
                                  killer: GameContext.resolve(e.killer, players: players),
                                  assisters: e.assisters.compactMap { GameContext.resolve($0, players: players) }))
        }
        return out.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
    }
}
