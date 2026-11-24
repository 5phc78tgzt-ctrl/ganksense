import Foundation

/// patterns across the last games with a result (summoner's rift records only; aram is never stored). a pure
/// function over the records: causes come from `DeathAnalyzer` and are estimates, so every sentence says "likely".
public struct GamePatterns: Sendable, Equatable {
    public static let window = 10
    public static let minGames = 3
    /// a top cause or killer is only reported with at least this many deaths, this many of them, and this share.
    static let minDeaths = 5
    static let minRepeat = 3
    static let minShare = 0.25
    /// the early-death figure counts deaths before this time (the "deaths before 14:00" goal).
    static let earlyLimit = 840.0
    static let trendGames = 5
    static let trendMinPrevious = 3
    static let trendStep = 0.3
    static let earlySuggestionAverage = 1.5

    public struct Cause: Sendable, Equatable {
        public var cause: DeathCause
        public var count: Int
        public var share: Double
        public var percent: Int { Int((share * 100).rounded()) }
    }

    public struct Killer: Sendable, Equatable {
        public var champion: String
        public var count: Int
        public var share: Double
        public var percent: Int { Int((share * 100).rounded()) }
    }

    public enum Direction: Sendable, Equatable { case improving, steady, worsening }

    public struct Trend: Sendable, Equatable {
        public var recent: Double
        public var previous: Double
        public var direction: Direction
    }

    public struct GoalRecord: Sendable, Equatable {
        public var met: Int
        public var nearMiss: Int
        public var missed: Int
        public var total: Int { met + nearMiss + missed }
    }

    public struct Suggestion: Sendable, Equatable {
        public var preset: GoalPreset
        public var text: String
    }

    public let games: Int
    public let deaths: Int
    public let topCause: Cause?
    /// average deaths per game before 14:00.
    public let earlyDeathsPerGame: Double
    public let trend: Trend?
    public let topKiller: Killer?
    public let goals: GoalRecord?
    public let suggestion: Suggestion?

    /// nil below `minGames` games with a result.
    public static func compute(records: [GameRecord]) -> GamePatterns? {
        let recent = records.filter { !$0.isVoid && $0.win != nil }.sorted { $0.date > $1.date }.prefix(window)
        guard recent.count >= minGames else { return nil }

        var causes: [DeathCause: Int] = [:]
        var killers: [String: Int] = [:]
        var deathCount = 0, killerCount = 0
        for record in recent {
            deathCount += record.deaths.count
            for a in DeathAnalyzer.analyze(record) where a.primary != .unclear { causes[a.primary, default: 0] += 1 }
            for k in record.deaths.compactMap(\.killer) where ![GameContext.turretMarker, GameContext.minionMarker,
                                                                GameContext.monsterMarker].contains(k) {
                killers[k, default: 0] += 1; killerCount += 1
            }
        }

        let topCause = causes.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }
            .flatMap { c -> Cause? in
                let share = Double(c.value) / Double(max(deathCount, 1))
                return deathCount >= minDeaths && c.value >= minRepeat && share >= minShare
                    ? Cause(cause: c.key, count: c.value, share: share) : nil
            }
        let topKiller = killers.max { ($0.value, $1.key) < ($1.value, $0.key) }
            .flatMap { k -> Killer? in
                let share = Double(k.value) / Double(max(killerCount, 1))
                return killerCount >= minDeaths && k.value >= minRepeat && share >= minShare
                    ? Killer(champion: k.key, count: k.value, share: share) : nil
            }

        let early = average(Array(recent))
        var trend: Trend?
        if recent.count >= trendGames + trendMinPrevious {
            let now = average(Array(recent.prefix(trendGames))), before = average(Array(recent.dropFirst(trendGames)))
            let direction: Direction = now <= before - trendStep ? .improving : now >= before + trendStep ? .worsening : .steady
            trend = Trend(recent: now, previous: before, direction: direction)
        }

        let results = recent.compactMap { $0.goalResult?.state }
        let record = GoalRecord(met: results.filter { $0 == .achieved || $0 == .onTrack }.count,
                                nearMiss: results.filter { $0 == .close }.count,
                                missed: results.filter { $0 == .failed }.count)

        return GamePatterns(games: recent.count, deaths: deathCount, topCause: topCause, earlyDeathsPerGame: early,
                            trend: trend, topKiller: topKiller, goals: record.total > 0 ? record : nil,
                            suggestion: suggestion(cause: topCause?.cause, early: early))
    }

    private static func average(_ games: [GameRecord]) -> Double {
        guard !games.isEmpty else { return 0 }
        return Double(games.reduce(0) { $0 + $1.deaths.filter { $0.time < earlyLimit }.count }) / Double(games.count)
    }

    private static func suggestion(cause: DeathCause?, early: Double) -> Suggestion? {
        let earlyGoal = Suggestion(preset: .deathsBefore14,
                                   text: "Early deaths are frequent. Try the goal: \(GoalPreset.deathsBefore14.title).")
        guard let cause else { return early >= earlySuggestionAverage ? earlyGoal : nil }
        switch cause {
        case .junglerGank:
            return Suggestion(preset: .deathsBefore14,
                              text: "Ganks may be costing you early. Try the goal: \(GoalPreset.deathsBefore14.title).")
        case .tiltRush:
            return Suggestion(preset: .totalDeaths,
                              text: "Quick re-deaths show up often. Try the goal: \(GoalPreset.totalDeaths.title).")
        case .teamfight, .objectiveFight, .outnumbered:
            return Suggestion(preset: .totalDeaths,
                              text: "Many deaths come in group fights. Try the goal: \(GoalPreset.totalDeaths.title).")
        case .soloKill, .matchup, .turret, .minions, .powerSpike:
            return early >= earlySuggestionAverage ? earlyGoal
                : Suggestion(preset: .totalDeaths, text: "Try the goal: \(GoalPreset.totalDeaths.title).")
        case .behind, .ahead, .early, .unclear:
            return nil
        }
    }

    /// "most common likely cause: jungler gank (41% of deaths)".
    public var causeLine: String? {
        topCause.map { "\($0.percent)% of your deaths: likely \($0.cause.phrase)" }
    }

    public var earlyLine: String {
        "Before 14:00: \(String(format: "%.1f", earlyDeathsPerGame)) deaths per game"
    }

    public var trendLine: String? {
        guard let t = trend else { return nil }
        let word = switch t.direction {
        case .improving: "down from"
        case .worsening: "up from"
        case .steady: "same as"
        }
        return "Last \(Self.trendGames) games: \(String(format: "%.1f", t.recent)) early deaths, \(word) \(String(format: "%.1f", t.previous))"
    }

    public var killerLine: String? {
        topKiller.map { "Most deaths to one champion: \($0.champion) (\($0.count))" }
    }

    /// one line for the review window footer.
    public var reviewLine: String? {
        if let c = topCause { return "Last \(games) games: most common likely cause was \(c.cause.phrase) (\(c.percent)% of deaths)" }
        if early >= 1 { return "Last \(games) games: \(String(format: "%.1f", earlyDeathsPerGame)) deaths per game before 14:00" }
        return nil
    }

    private var early: Double { earlyDeathsPerGame }
}
