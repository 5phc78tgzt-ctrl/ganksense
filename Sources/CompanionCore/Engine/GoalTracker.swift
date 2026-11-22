public enum GoalPreset: String, Codable, CaseIterable, Sendable {
    case deathsBefore14, csAt10, csPerMinAt20, killParticipation, totalDeaths, goldAt15

    public var title: String {
        switch self {
        case .deathsBefore14: "Deaths before 14:00"
        case .csAt10: "CS at 10:00"
        case .csPerMinAt20: "CS per minute at 20:00"
        case .killParticipation: "Kill participation"
        case .totalDeaths: "Deaths this game"
        case .goldAt15: "Gold at 15:00"
        }
    }

    /// unit of `target`. kill participation targets are fractions (0.5 = 50 %).
    public var unit: String {
        switch self {
        case .deathsBefore14, .totalDeaths: "deaths"
        case .csAt10: "CS"
        case .csPerMinAt20: "CS/min"
        case .killParticipation: "%"
        case .goldAt15: "gold"
        }
    }

    public var lowerIsBetter: Bool { self == .deathsBefore14 || self == .totalDeaths }

    public var defaultTarget: Double {
        switch self {
        case .deathsBefore14: 2
        case .totalDeaths: 5
        case .csAt10: 70
        case .csPerMinAt20: 7
        case .killParticipation: 0.5
        case .goldAt15: 5500
        }
    }

    var deadline: Double? {
        switch self {
        case .deathsBefore14: 840
        case .csAt10: 600
        case .goldAt15: 900
        case .csPerMinAt20: 1200
        case .killParticipation, .totalDeaths: nil
        }
    }
}

public struct Goal: Codable, Sendable, Equatable {
    public var preset: GoalPreset
    public var target: Double

    public init(preset: GoalPreset, target: Double) {
        self.preset = preset; self.target = target
    }
}

public enum GoalState: String, Codable, Sendable {
    case onTrack, close, failed, achieved, pending
}

public struct GoalProgress: Codable, Sendable, Equatable {
    public var goal: Goal
    public var current: Double
    public var state: GoalState
    public var label: String
    public var deadline: Double?

    public init(goal: Goal, current: Double, state: GoalState, label: String, deadline: Double? = nil) {
        self.goal = goal; self.current = current; self.state = state; self.label = label; self.deadline = deadline
    }
}

/// snapshots carry no history, so for time-boxed goals (cs at 10, gold at 15) a snapshot taken after the
/// deadline can only estimate the value at the deadline (linear pace). the first evaluation at or just after the
/// deadline is exact, so the caller should keep the first `achieved`/`failed` result it sees.
public struct GoalTracker {
    private static let closeRatio = 0.85
    /// seconds after the deadline for which the raw value is still treated as "at the deadline".
    private static let deadlineGrace = 5.0
    private static let startingGold = 500.0

    public static func evaluate(_ goal: Goal, snapshot: LiveGameSnapshot, catalog: ItemCatalog?, final: Bool) -> GoalProgress {
        let preset = goal.preset, target = goal.target
        let deadline = preset.deadline
        let t = snapshot.gameData?.gameTime ?? 0

        func progress(_ current: Double, _ state: GoalState) -> GoalProgress {
            GoalProgress(goal: goal, current: current, state: state,
                         label: label(preset, current, target), deadline: deadline)
        }
        guard let me = snapshot.me else {
            return GoalProgress(goal: goal, current: 0, state: final ? .failed : .pending,
                                label: "Waiting for game data", deadline: deadline)
        }

        switch preset {
        case .deathsBefore14, .totalDeaths:
            let current: Double
            if preset == .deathsBefore14 {
                let before = DeathRecorder.deaths(in: snapshot).filter { $0.time < 840 }.count
                // before 14:00 every death counts; the scoreboard may be ahead of the event list.
                current = Double(t < 840 ? max(before, me.scores.deaths) : before)
            } else {
                current = Double(me.scores.deaths)
            }
            // deaths never decrease, so exceeding the target is final immediately.
            if current > target { return progress(current, .failed) }
            if final || (deadline.map { t >= $0 } ?? false) { return progress(current, .achieved) }
            let oneLeft = current >= target - 1
            return progress(current, (oneLeft || current >= closeRatio * target) ? .close : .onTrack)

        case .csAt10:
            return paced(progress, deadline: 600, t: t, final: final, target: target,
                         value: estimate(Double(me.scores.creepScore), t: t, deadline: 600, floor: 0),
                         expected: { target * $0 / 600 })

        case .goldAt15:
            let gold = totalGold(snapshot, me: me, catalog: catalog)
            return paced(progress, deadline: 900, t: t, final: final, target: target,
                         value: estimate(gold, t: t, deadline: 900, floor: startingGold),
                         expected: { startingGold + (target - startingGold) * $0 / 900 })

        case .csPerMinAt20:
            let current = t >= 60 ? Double(me.scores.creepScore) / (t / 60) : 0
            if final || t >= 1200 { return progress(current, current >= target ? .achieved : .failed) }
            if t < 300 { return progress(current, .pending) }
            return progress(current, byRatio(current / target))

        case .killParticipation:
            let teamKills = snapshot.allPlayers.filter { $0.team == me.team }.reduce(0) { $0 + $1.scores.kills }
            let current = teamKills > 0 ? Double(me.scores.kills + me.scores.assists) / Double(teamKills) : 0
            if final { return progress(current, current >= target ? .achieved : .failed) }
            if teamKills < 5 { return progress(current, .pending) }
            return progress(current, byRatio(current / target))
        }
    }

    private static func paced(_ progress: (Double, GoalState) -> GoalProgress, deadline: Double, t: Double,
                              final: Bool, target: Double, value: Double,
                              expected: (Double) -> Double) -> GoalProgress {
        if final || t >= deadline { return progress(value, value >= target ? .achieved : .failed) }
        if t < 0.25 * deadline { return progress(value, .pending) }
        return progress(value, byRatio(value / expected(t)))
    }

    private static func estimate(_ raw: Double, t: Double, deadline: Double, floor: Double) -> Double {
        guard t > deadline + deadlineGrace else { return raw }
        return floor + (raw - floor) * deadline / t
    }

    /// falling behind pace before the deadline is "pending" (undecided), never "failed".
    private static func byRatio(_ r: Double) -> GoalState {
        if r >= 1 { return .onTrack }
        if r >= closeRatio { return .close }
        return .pending
    }

    private static func totalGold(_ s: LiveGameSnapshot, me: Player, catalog: ItemCatalog?) -> Double {
        let items = me.items.reduce(0.0) { sum, it in
            let value = catalog?.item(it.itemID)?.goldTotal ?? it.price ?? 0
            return sum + Double(value * max(1, it.count))
        }
        return (s.activePlayer?.currentGold ?? 0) + items
    }

    private static func label(_ preset: GoalPreset, _ current: Double, _ target: Double) -> String {
        switch preset {
        case .killParticipation: "\(Int((current * 100).rounded())) / \(Int((target * 100).rounded())) %"
        case .csPerMinAt20: "\(oneDecimal(current)) / \(oneDecimal(target)) CS/min"
        default: "\(Int(current.rounded())) / \(Int(target.rounded())) \(preset.unit)"
        }
    }

    private static func oneDecimal(_ x: Double) -> String {
        let tenths = Int((x * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
