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

    /// goal title at the preset's default minute.
    public var shortName: String {
        switch self {
        case .deathsBefore14: "Deaths before"
        case .csAt10: "CS at"
        case .csPerMinAt20: "CS per minute at"
        case .killParticipation: "Kill participation"
        case .totalDeaths: "Deaths this game"
        case .goldAt15: "Gold at"
        }
    }

    /// goals with a user-adjustable minute.
    public var hasMinutes: Bool { defaultMinutes != nil }

    public var defaultMinutes: Int? {
        switch self {
        case .deathsBefore14: 14
        case .csAt10: 10
        case .csPerMinAt20: 20
        case .goldAt15: 15
        case .killParticipation, .totalDeaths: nil
        }
    }

    public static let minutesRange = 5...30

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

}

public struct Goal: Codable, Sendable, Equatable {
    public var preset: GoalPreset
    public var target: Double
    /// deadline minute for time-based presets; nil for the others. old stored goals decode to the preset's default.
    public var minutes: Int?

    public init(preset: GoalPreset, target: Double, minutes: Int? = nil) {
        self.preset = preset; self.target = target
        self.minutes = preset.hasMinutes ? Self.clamp(minutes ?? preset.defaultMinutes!) : nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try c.decode(GoalPreset.self, forKey: .preset), target: try c.decode(Double.self, forKey: .target),
                  minutes: try? c.decodeIfPresent(Int.self, forKey: .minutes))
    }

    private enum CodingKeys: String, CodingKey { case preset, target, minutes }

    static func clamp(_ m: Int) -> Int { min(max(m, GoalPreset.minutesRange.lowerBound), GoalPreset.minutesRange.upperBound) }

    public var deadline: Double? { minutes.map { Double($0 * 60) } }

    public var title: String { minutes.map { "\(preset.shortName) \($0):00" } ?? preset.title }
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

    /// `before`: the last reading (game time, raw value) taken at or before the deadline. with it a late first
    /// look past the deadline interpolates between the two readings instead of guessing from a linear pace.
    public static func evaluate(_ goal: Goal, snapshot: LiveGameSnapshot, catalog: ItemCatalog?, final: Bool,
                                before: (t: Double, value: Double)? = nil) -> GoalProgress {
        let preset = goal.preset, target = goal.target
        let deadline = goal.deadline
        let t = snapshot.gameData?.gameTime ?? 0

        func progress(_ current: Double, _ state: GoalState) -> GoalProgress {
            GoalProgress(goal: goal, current: current, state: state,
                         label: label(goal, current, deadline: deadline, t: t), deadline: deadline)
        }
        guard let me = snapshot.me else {
            return GoalProgress(goal: goal, current: 0, state: final ? .failed : .pending,
                                label: "Waiting for game data", deadline: deadline)
        }

        switch preset {
        case .deathsBefore14, .totalDeaths:
            let current: Double
            if preset == .deathsBefore14 {
                let limit = deadline ?? 840
                let before = DeathRecorder.deaths(in: snapshot).filter { $0.time < limit }.count
                // before the deadline every death counts; the scoreboard may be ahead of the event list.
                current = Double(t < limit ? max(before, me.scores.deaths) : before)
            } else {
                current = Double(me.scores.deaths)
            }
            // deaths never decrease, so exceeding the target is final immediately.
            if current > target { return progress(current, .failed) }
            if final || (deadline.map { t >= $0 } ?? false) { return progress(current, .achieved) }
            let oneLeft = current >= target - 1
            return progress(current, (oneLeft || current >= closeRatio * target) ? .close : .onTrack)

        case .csAt10:
            let d = deadline ?? 600
            return paced(progress, deadline: d, t: t, final: final, target: target,
                         value: estimate(Double(me.scores.creepScore), t: t, deadline: d, floor: 0, before: before),
                         expected: { target * $0 / d })

        case .goldAt15:
            let gold = totalGold(snapshot, me: me, catalog: catalog)
            let d = deadline ?? 900
            return paced(progress, deadline: d, t: t, final: final, target: target,
                         value: estimate(gold, t: t, deadline: d, floor: startingGold, before: before),
                         expected: { startingGold + (target - startingGold) * $0 / d })

        case .csPerMinAt20:
            let current = t >= 60 ? Double(me.scores.creepScore) / (t / 60) : 0
            let d = deadline ?? 1200
            if final || t >= d { return progress(current, current >= target ? .achieved : .failed) }
            if t < d / 4 { return progress(current, .pending) }
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

    /// the raw value a paced goal tracks (nil for the other presets), for the caller's `before` readings.
    public static func pacedValue(_ goal: Goal, snapshot: LiveGameSnapshot, catalog: ItemCatalog?) -> Double? {
        guard let me = snapshot.me else { return nil }
        switch goal.preset {
        case .csAt10: return Double(me.scores.creepScore)
        case .goldAt15: return totalGold(snapshot, me: me, catalog: catalog)
        default: return nil
        }
    }

    private static func estimate(_ raw: Double, t: Double, deadline: Double, floor: Double,
                                 before: (t: Double, value: Double)? = nil) -> Double {
        guard t > deadline else { return raw }
        if let before, before.t <= deadline, t > before.t {
            let f = (deadline - before.t) / (t - before.t)
            return before.value + (raw - before.value) * f
        }
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
            let item = catalog?.item(it.itemID)
            // potions, wards and elixirs are used up: counting them would make held gold look higher than it is.
            if item?.tags.contains("Consumable") == true { return sum }
            let value = item?.goldTotal ?? it.price ?? 0
            return sum + Double(value * max(1, it.count))
        }
        return (s.activePlayer?.currentGold ?? 0) + items
    }

    private static func label(_ goal: Goal, _ current: Double, deadline: Double?, t: Double) -> String {
        let preset = goal.preset, target = goal.target
        switch preset {
        case .killParticipation: return "\(Int((current * 100).rounded()))% / \(Int((target * 100).rounded()))%"
        case .csPerMinAt20: return "\(oneDecimal(current)) / \(oneDecimal(target)) CS/min"
        default:
            let base = "\(Int(current.rounded())) / \(Int(target.rounded())) \(preset.unit)"
            // paced goals show the clock so the value reads as progress against the benchmark.
            guard preset == .csAt10 || preset == .goldAt15, let deadline, t > 0, t < deadline else { return base }
            let sec = Int(t)
            return "\(base) · \(sec / 60):\(String(format: "%02d", sec % 60))"
        }
    }

    private static func oneDecimal(_ x: Double) -> String {
        let tenths = Int((x * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
