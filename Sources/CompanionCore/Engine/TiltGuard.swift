import Foundation

public struct TiltSettings: Codable, Sendable, Equatable {
    public var lossStreak: Int
    public var sessionHours: Double
    public var enabled: Bool
    public init(lossStreak: Int = 3, sessionHours: Double = 2.5, enabled: Bool = true) {
        self.lossStreak = lossStreak
        self.sessionHours = sessionHours
        self.enabled = enabled
    }
}

public enum TiltReason: Sendable, Equatable {
    case lossStreak(Int)
    case longSession(hours: Double)
}

public struct TiltStatus: Sendable, Equatable {
    public var reason: TiltReason?
    public var todayWins: Int
    public var todayLosses: Int
    public var currentLossStreak: Int
    public var message: String?
    public init(reason: TiltReason?, todayWins: Int, todayLosses: Int, currentLossStreak: Int, message: String?) {
        self.reason = reason
        self.todayWins = todayWins
        self.todayLosses = todayLosses
        self.currentLossStreak = currentLossStreak
        self.message = message
    }
}

public enum TiltGuard {
    static let sessionGap: TimeInterval = 45 * 60

    /// `matches` newest-first. "today" begins at the most recent 05:00 in `calendar`.
    public static func evaluate(
        matches: [MatchSummary],
        sessionStart: Date?,
        now: Date,
        settings: TiltSettings,
        calendar: Calendar = .current
    ) -> TiltStatus {
        let games = matches.filter { !$0.remake }.sorted { $0.start > $1.start }

        var dayStart = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now) ?? now
        if dayStart > now { dayStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart }
        let today = games.filter { $0.start >= dayStart && $0.start <= now }
        let wins = today.filter(\.win).count
        let losses = today.count - wins

        var streak = 0
        for g in games { if g.win { break } else { streak += 1 } }

        var status = TiltStatus(reason: nil, todayWins: wins, todayLosses: losses, currentLossStreak: streak, message: nil)
        guard settings.enabled else { return status }

        if streak >= settings.lossStreak {
            status.reason = .lossStreak(streak)
            status.message = "\(streak) losses in a row. A short break usually helps."
            return status
        }

        // session: consecutive games with < 45 min gaps, newest ended <= 45 min ago.
        var chainStart: Date?
        if let newest = games.first,
           now.timeIntervalSince(newest.start.addingTimeInterval(TimeInterval(newest.durationSec))) <= sessionGap {
            chainStart = newest.start
            for (newer, older) in zip(games, games.dropFirst()) {
                let olderEnd = older.start.addingTimeInterval(TimeInterval(older.durationSec))
                guard newer.start.timeIntervalSince(olderEnd) < sessionGap else { break }
                chainStart = older.start
            }
        }
        if let start = [chainStart, sessionStart].compactMap({ $0 }).min() {
            let hours = now.timeIntervalSince(start) / 3600
            if hours >= settings.sessionHours {
                status.reason = .longSession(hours: hours)
                status.message = "You've played \(String(format: "%.1f", hours)) hours. Time for a stretch?"
            }
        }
        return status
    }
}
