import Foundation

/// figures derived from the stored games (goal streak, last play session, death causes).
struct HistoryStats {
    var goalStreak: Int
    var lastSession: (wins: Int, losses: Int)?
    var deathCauses: [DeathCause: Int]

    private static let deathCauseWindow = 20

    init(records: [GameRecord]) {
        let newest = records.sorted { $0.date > $1.date }
        let played = newest.filter { !$0.isVoid }
        goalStreak = Self.goalStreak(newestPlayed: played)
        lastSession = Self.lastSession(newestPlayed: played)
        deathCauses = Self.deathCauses(newest.prefix(Self.deathCauseWindow))
    }

    private static func goalStreak(newestPlayed: [GameRecord]) -> Int {
        var streak = 0
        for record in newestPlayed {
            guard let goal = record.goalResult else { continue }
            guard goal.state == .achieved else { break }
            streak += 1
        }
        return streak
    }

    /// games count toward one session while each starts less than the session gap after the previous one ended.
    private static func lastSession(newestPlayed: [GameRecord]) -> (wins: Int, losses: Int)? {
        guard let first = newestPlayed.first else { return nil }
        var wins = 0, losses = 0
        var newer = first
        for record in newestPlayed {
            if record.id != first.id {
                let olderEnd = record.date.addingTimeInterval(record.durationSec)
                guard newer.date.timeIntervalSince(olderEnd) < TiltGuard.sessionGap else { break }
            }
            switch record.win {
            case true?: wins += 1
            case false?: losses += 1
            case nil: break
            }
            newer = record
        }
        return (wins, losses)
    }

    private static func deathCauses(_ records: ArraySlice<GameRecord>) -> [DeathCause: Int] {
        var causes: [DeathCause: Int] = [:]
        for record in records {
            for analysis in DeathAnalyzer.analyze(record) { causes[analysis.primary, default: 0] += 1 }
        }
        return causes
    }
}
