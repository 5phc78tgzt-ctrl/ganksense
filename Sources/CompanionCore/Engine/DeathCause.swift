import Foundation

/// a likely cause of a death, or a factor around it. everything here is an estimate from kill-feed and
/// scoreboard data: the live client api has no positions, vision or intent, so none of those is ever claimed.
public enum DeathCause: String, Codable, CaseIterable, Sendable {
    case junglerGank, teamfight, objectiveFight, turret, matchup, outnumbered, soloKill, powerSpike, tiltRush
    case minions
    /// modifiers: shown as secondary factors only, never as the primary cause.
    case behind, ahead, early
    case unclear

    public var phrase: String {
        switch self {
        case .junglerGank: "jungler gank"
        case .teamfight: "teamfight"
        case .objectiveFight: "objective fight"
        case .turret: "turret kill"
        case .matchup: "losing the matchup"
        case .outnumbered: "outnumbered / caught"
        case .soloKill: "lost a 1v1 / outplayed"
        case .powerSpike: "enemy power spike"
        case .tiltRush: "tilt / rush"
        case .minions: "killed by minions"
        case .behind: "behind on kills"
        case .ahead: "ahead on kills"
        case .early: "early death"
        case .unclear: "unclear"
        }
    }

    public var chip: String {
        switch self {
        case .junglerGank: "Jungler gank"
        case .teamfight: "Teamfight"
        case .objectiveFight: "Objective"
        case .turret: "Turret"
        case .matchup: "Matchup"
        case .outnumbered: "Outnumbered"
        case .soloKill: "Solo kill"
        case .powerSpike: "Enemy spike"
        case .tiltRush: "Quick re-death"
        case .minions: "Minions"
        case .behind: "Behind"
        case .ahead: "Ahead"
        case .early: "Early"
        case .unclear: "Unclear"
        }
    }

    public var isModifier: Bool { self == .behind || self == .ahead || self == .early }

    fileprivate var priority: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

public enum DeathConfidence: Int, Comparable, Sendable {
    case low, medium, high
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct DeathAnalysis: Sendable, Equatable, Identifiable {
    public var id: Int { deathID }
    public var deathID: Int
    public var primary: DeathCause
    public var secondary: [DeathCause]
    public var confidence: DeathConfidence
    public var evidence: String

    public var title: String {
        switch (primary, confidence) {
        case (.unclear, _): "Unclear"
        case (_, .low): "Possibly \(primary.phrase)"
        default: primary.phrase.prefix(1).uppercased() + primary.phrase.dropFirst()
        }
    }

    public var headline: String {
        switch (primary, confidence) {
        case (.unclear, _): "Unclear"
        case (_, .low): "Possibly \(primary.phrase)"
        default: "Likely \(primary.phrase)"
        }
    }
}

/// estimates why each of my deaths happened from the data already collected: the kill feed (killer, assisters,
/// other deaths, objectives), the roster (summoner spells → enemy jungler), enemy power spikes seen live, and my
/// own earlier deaths. pure and deterministic; each signal adds a scored candidate, the strongest eligible one
/// becomes the primary cause, up to two others become secondary factors, and weak signals give "unclear".
///
/// what it cannot see: positions, vision, wards, cooldowns, intent. "jungler gank" means an enemy with smite was
/// among the killers, not that a gank was seen; "teamfight" means other champions died within seconds.
public enum DeathAnalyzer {
    // tuning (seconds).
    static let nearbyWindow = 10.0
    static let objectiveWindow = 15.0
    static let spikeWindow = 120.0
    static let rushGap = 90.0
    static let earlyLimit = 240.0
    /// a candidate needs at least this score to be the primary cause / a secondary factor.
    static let primaryThreshold = 0.45
    static let secondaryThreshold = 0.30

    public static func analyze(_ record: GameRecord) -> [DeathAnalysis] {
        analyze(deaths: record.deaths, context: record.context)
    }

    public static func analyze(deaths: [DeathEvent], context: GameContext?) -> [DeathAnalysis] {
        let ordered = deaths.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let hasLog = context != nil
        let ctx = context ?? GameContext()
        var byKiller: [String: Int] = [:]
        for d in ordered { if let k = killerKey(d.killer, ctx) { byKiller[k, default: 0] += 1 } }
        return ordered.enumerated().map { i, d in
            analyzeOne(d, previous: i > 0 ? ordered[i - 1] : nil, ctx: ctx, hasLog: hasLog, killerCounts: byKiller)
        }
    }

    private struct Candidate {
        var cause: DeathCause
        var score: Double
        var evidence: String
    }

    /// everything the signal builders need about one death, resolved once.
    private struct Scene {
        let death: DeathEvent
        let ctx: GameContext
        let hasLog: Bool
        let killer: GameContext.Participant?
        let involvedEnemies: [GameContext.Participant]
        let neutralKiller: Neutral?
        let killerLabel: String
        let names: String
        let nearby: [GameContext.LoggedEvent]
        let nearbyAllies: Int

        func participant(_ name: String?) -> GameContext.Participant? { ctx.participants.first { $0.matches(name) } }
    }

    private static func scene(for d: DeathEvent, ctx: GameContext, hasLog: Bool) -> Scene {
        func participant(_ name: String?) -> GameContext.Participant? { ctx.participants.first { $0.matches(name) } }
        let killerP = participant(d.killer)
        let assistersP = d.assisters.map { (name: $0, p: participant($0)) }
        let involvedEnemies: [GameContext.Participant] =
            ([killerP] + assistersP.map(\.p)).compactMap { $0 }.filter { !$0.isAlly }
        let killerLabel = killerP?.champion ?? d.killer.flatMap { neutralKind($0) == nil ? $0 : nil }
            ?? neutralKind(d.killer).map(\.label) ?? "unknown"
        let nearby = ctx.events.filter { e in
            guard e.name == "ChampionKill", e.id != d.id, abs(e.time - d.time) <= nearbyWindow else { return false }
            return !(participant(e.victim)?.isMe ?? false)
        }
        return Scene(death: d, ctx: ctx, hasLog: hasLog, killer: killerP, involvedEnemies: involvedEnemies,
                     neutralKiller: killerP == nil ? d.killer.flatMap(neutralKind) : nil, killerLabel: killerLabel,
                     names: ([killerLabel] + assistersP.map { $0.p?.champion ?? $0.name }).joined(separator: " + "),
                     nearby: nearby, nearbyAllies: nearby.filter { participant($0.victim)?.isAlly == true }.count)
    }

    private static func analyzeOne(_ d: DeathEvent, previous: DeathEvent?, ctx: GameContext, hasLog: Bool,
                                   killerCounts: [String: Int]) -> DeathAnalysis {
        let scene = scene(for: d, ctx: ctx, hasLog: hasLog)
        let candidates = [
            neutralCandidates(scene), junglerCandidates(scene), teamfightCandidates(scene),
            objectiveCandidates(scene), outnumberedCandidates(scene), soloKillCandidates(scene),
            matchupCandidates(scene, killerCounts: killerCounts), spikeCandidates(scene),
            rushCandidates(scene, previous: previous), balanceCandidates(scene), earlyCandidates(scene),
        ].flatMap { $0 }
        return resolve(candidates, scene: scene)
    }

    private static func resolve(_ candidates: [Candidate], scene: Scene) -> DeathAnalysis {
        let ranked = candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.cause.priority < $1.cause.priority }
        let primary = ranked.first { !$0.cause.isModifier && $0.score >= primaryThreshold }
        var secondary: [DeathCause] = []
        for cand in ranked where cand.cause != primary?.cause && cand.score >= secondaryThreshold {
            if !secondary.contains(cand.cause) { secondary.append(cand.cause) }
            if secondary.count == 2 { break }
        }
        let id = scene.death.id
        guard let primary else {
            return DeathAnalysis(deathID: id, primary: .unclear, secondary: secondary, confidence: .low,
                                 evidence: "\(scene.names) · no clear signal in the kill feed")
        }
        let confidence: DeathConfidence = primary.score >= 0.7 ? .high : primary.score >= 0.55 ? .medium : .low
        return DeathAnalysis(deathID: id, primary: primary.cause, secondary: secondary, confidence: confidence,
                             evidence: "\(scene.names) · \(primary.evidence)")
    }

    private static func neutralCandidates(_ s: Scene) -> [Candidate] {
        switch s.neutralKiller {
        case .turret?: [Candidate(cause: .turret, score: 0.75, evidence: "killed by a turret")]
        case .minions?: [Candidate(cause: .minions, score: 0.35, evidence: "killed by minions")]
        case .monster?: [Candidate(cause: .objectiveFight, score: 0.8, evidence: "killed by a neutral monster")]
        case nil: []
        }
    }

    private static func junglerCandidates(_ s: Scene) -> [Candidate] {
        guard let jungler = s.involvedEnemies.first(where: \.looksLikeJungler) else { return [] }
        let big = s.nearby.count >= 3
        return [Candidate(cause: .junglerGank, score: big ? 0.5 : 0.8,
                          evidence: "enemy jungler involved (\(jungler.champion))")]
    }

    private static func teamfightCandidates(_ s: Scene) -> [Candidate] {
        guard s.hasLog, !s.nearby.isEmpty else { return [] }
        let n = s.nearby.count
        let score = n >= 3 ? 0.85 : n == 2 ? 0.65 : 0.42
        return [Candidate(cause: .teamfight, score: score,
                          evidence: "\(n) other champion\(n == 1 ? "" : "s") died within \(Int(nearbyWindow)) s")]
    }

    private static func objectiveCandidates(_ s: Scene) -> [Candidate] {
        guard s.hasLog else { return [] }
        let time = s.death.time
        let objectives = s.ctx.events.filter { objectiveName($0.name) != nil && abs($0.time - time) <= objectiveWindow }
        guard let e = objectives.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return [] }
        let major = e.name != "TurretKilled" && e.name != "InhibKilled"
        let by = s.participant(e.killer).map { $0.isAlly ? "your team" : "the enemy team" }
        let dt = Int((e.time - time).rounded())
        let when = dt == 0 ? "at the same time" : dt > 0 ? "\(dt) s later" : "\(-dt) s earlier"
        let what = objectiveName(e.name) ?? "an objective"
        return [Candidate(cause: .objectiveFight, score: major ? 0.7 : 0.5,
                          evidence: by.map { "\(what) taken by \($0) \(when)" } ?? "\(what) taken \(when)")]
    }

    private static func outnumberedCandidates(_ s: Scene) -> [Candidate] {
        guard s.hasLog, s.involvedEnemies.count >= 2, s.nearbyAllies == 0 else { return [] }
        let n = s.involvedEnemies.count
        return [Candidate(cause: .outnumbered, score: n >= 3 ? 0.7 : 0.6,
                          evidence: "\(n) enemies involved, no teammate died within \(Int(nearbyWindow)) s")]
    }

    private static func soloKillCandidates(_ s: Scene) -> [Candidate] {
        guard let killer = s.killer, !killer.isAlly, s.death.assisters.isEmpty else { return [] }
        let crowded = s.hasLog && !s.nearby.isEmpty
        let evidence = s.hasLog && s.nearby.isEmpty ? "no assists, nobody else died within \(Int(nearbyWindow)) s" : "no assists"
        return [Candidate(cause: .soloKill, score: crowded ? 0.5 : 0.6, evidence: evidence)]
    }

    private static func matchupCandidates(_ s: Scene, killerCounts: [String: Int]) -> [Candidate] {
        guard let key = killerKey(s.death.killer, s.ctx), let n = killerCounts[key], n >= 3 else { return [] }
        return [Candidate(cause: .matchup, score: 0.7, evidence: "\(n) of your deaths were to \(s.killerLabel)")]
    }

    private static func spikeCandidates(_ s: Scene) -> [Candidate] {
        let champions = Set(s.involvedEnemies.map(\.champion))
        let time = s.death.time
        let recent = s.ctx.spikes.filter { champions.contains($0.champion) && $0.time <= time && time - $0.time <= spikeWindow }
        guard let spike = recent.max(by: { $0.time < $1.time }) else { return [] }
        let ago = Int((time - spike.time).rounded())
        return [Candidate(cause: .powerSpike, score: spike.detail.contains("item") ? 0.5 : 0.4,
                          evidence: "\(spike.champion) spiked \(ago) s earlier (\(spike.detail))")]
    }

    private static func rushCandidates(_ s: Scene, previous: DeathEvent?) -> [Candidate] {
        guard let previous, s.death.time - previous.time < rushGap else { return [] }
        let gap = Int((s.death.time - previous.time).rounded())
        return [Candidate(cause: .tiltRush, score: 0.5, evidence: "died again \(gap) s after the previous death")]
    }

    private static func balanceCandidates(_ s: Scene) -> [Candidate] {
        guard s.hasLog, let killer = s.killer, !killer.isAlly else { return [] }
        let time = s.death.time
        let (mk, md) = balance(of: { $0.isMe }, before: time, s.ctx)
        let (kk, kd) = balance(of: { $0.champion == killer.champion }, before: time, s.ctx)
        let diff = (kk - kd) - (mk - md)
        let evidence = "you \(mk)/\(md) vs \(killer.champion) \(kk)/\(kd)"
        if diff >= 2 { return [Candidate(cause: .behind, score: 0.35, evidence: evidence)] }
        if diff <= -2 { return [Candidate(cause: .ahead, score: 0.3, evidence: evidence)] }
        return []
    }

    private static func earlyCandidates(_ s: Scene) -> [Candidate] {
        guard s.death.time < earlyLimit else { return [] }
        return [Candidate(cause: .early, score: 0.3, evidence: "before \(Int(earlyLimit) / 60):00")]
    }

    private enum Neutral { case turret, minions, monster
        var label: String { switch self { case .turret: "Turret"; case .minions: "Minions"; case .monster: "Monster" } }
    }

    private static func neutralKind(_ name: String?) -> Neutral? {
        switch name {
        case GameContext.turretMarker?: .turret
        case GameContext.minionMarker?: .minions
        case GameContext.monsterMarker?: .monster
        default: nil
        }
    }

    private static func objectiveName(_ event: String) -> String? {
        switch event {
        case "DragonKill": "Dragon"
        case "BaronKill": "Baron"
        case "HeraldKill": "Rift Herald"
        case "HordeKill": "Void Grubs"
        case "TurretKilled": "a turret"
        case "InhibKilled": "an inhibitor"
        default: nil
        }
    }

    /// stable key for "the same enemy again": the champion when the roster knows the killer, else the raw name.
    private static func killerKey(_ killer: String?, _ ctx: GameContext) -> String? {
        guard let killer, !killer.isEmpty, neutralKind(killer) == nil else { return nil }
        return ctx.participants.first { $0.matches(killer) }?.champion ?? killer.lowercased()
    }

    private static func balance(of pick: (GameContext.Participant) -> Bool, before time: Double,
                                _ ctx: GameContext) -> (kills: Int, deaths: Int) {
        guard let p = ctx.participants.first(where: pick) else { return (0, 0) }
        var k = 0, dth = 0
        for e in ctx.events where e.name == "ChampionKill" && e.time < time {
            if p.matches(e.killer) { k += 1 }
            if p.matches(e.victim) { dth += 1 }
        }
        return (k, dth)
    }
}
