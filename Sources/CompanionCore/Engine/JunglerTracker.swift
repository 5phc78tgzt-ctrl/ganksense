/// an informational "enemy jungler last seen" line. built only from live client data (kill feed, objective
/// events, dead state); it never claims a position. all fields are coarse on purpose so the value (and the
/// hud text) changes rarely: age buckets and 5 s respawn steps.
public struct JunglerStatus: Sendable, Hashable {
    public enum Place: Sendable, Hashable {
        case top, mid, bot, fighting, dragon, baron, topSide

        var phrase: String {
            switch self {
            case .top: "top"
            case .mid: "mid"
            case .bot: "bot"
            case .fighting: "fighting"
            case .dragon: "near Dragon"
            case .baron: "near Baron"
            case .topSide: "top side"
            }
        }
    }

    public enum Age: Sendable, Hashable {
        case justNow, underMinute, aboutMinute

        var phrase: String {
            switch self {
            case .justNow: "just now"
            case .underMinute: "<1 min ago"
            case .aboutMinute: "1 min ago"
            }
        }
    }

    public enum State: Sendable, Hashable {
        case dead(seconds: Int)
        case seen(Place, Age)
    }

    public var champion: String
    public var state: State

    public init(champion: String, state: State) {
        self.champion = champion; self.state = state
    }

    public var isDead: Bool {
        if case .dead = state { true } else { false }
    }

    public var headline: String {
        switch state {
        case .dead: "\(champion) dead"
        case .seen(let place, _): "\(champion) seen \(place.phrase)"
        }
    }

    public var detail: String {
        switch state {
        case .dead(let s): "back in ~\(s) s"
        case .seen(_, let age): age.phrase
        }
    }

    public var text: String { "\(headline) · \(detail)" }
}

/// derives `junglerstatus` from each snapshot. stateless (the full event list is in every snapshot), so a new
/// game just uses a new instance.
public struct JunglerTracker: Sendable {
    public static let maxAge: Double = 90
    static let objectiveEvents: [String: JunglerStatus.Place] = [
        "DragonKill": .dragon, "BaronKill": .baron, "HeraldKill": .topSide, "HordeKill": .topSide,
    ]

    public init() {}

    public mutating func update(_ snapshot: LiveGameSnapshot) -> JunglerStatus? {
        guard let jungler = Self.enemyJungler(in: snapshot) else { return nil }
        let name = jungler.championName
        if jungler.isDead {
            let secs = Int((max(jungler.respawnTimer, 0) / 5).rounded(.up)) * 5
            return JunglerStatus(champion: name, state: .dead(seconds: max(secs, 5)))
        }
        let now = snapshot.gameData?.gameTime ?? 0
        let enemyTeam = jungler.team

        var best: (time: Double, place: JunglerStatus.Place)?
        for e in snapshot.events {
            guard e.time <= now + 1, now - e.time <= Self.maxAge else { continue }
            var place: JunglerStatus.Place?
            if e.name == "ChampionKill" {
                guard jungler.isSameAs(e.killer) || e.assisters.contains(where: { jungler.isSameAs($0) }) else { continue }
                place = Self.lane(of: snapshot.allPlayers.first { $0.isSameAs(e.victim) }) ?? .fighting
            } else if let p = Self.objectiveEvents[e.name] {
                guard let killer = snapshot.allPlayers.first(where: { $0.isSameAs(e.killer) }),
                      killer.team == enemyTeam else { continue }
                place = p
            }
            if let place, best.map({ e.time >= $0.time }) ?? true { best = (e.time, place) }
        }
        guard let best else { return nil }
        let age = max(now - best.time, 0)
        let bucket: JunglerStatus.Age = age < 30 ? .justNow : age < 60 ? .underMinute : .aboutMinute
        return JunglerStatus(champion: name, state: .seen(best.place, bucket))
    }

    /// enemy with position jungle; else (position unknown) the enemy carrying smite.
    static func enemyJungler(in snapshot: LiveGameSnapshot) -> Player? {
        let enemies = snapshot.enemies
        if let p = enemies.first(where: { $0.position?.uppercased() == "JUNGLE" }) { return p }
        return enemies.first { p in
            (p.position ?? "").isEmpty && p.summonerSpellNames.contains { $0.localizedCaseInsensitiveContains("smite") }
        }
    }

    private static func lane(of victim: Player?) -> JunglerStatus.Place? {
        switch victim?.position?.uppercased() {
        case "TOP": .top
        case "MIDDLE", "MID": .mid
        case "BOTTOM", "UTILITY": .bot
        default: nil
        }
    }
}
