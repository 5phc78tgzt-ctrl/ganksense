import Foundation
@testable import CompanionCore

func patternGame(_ i: Int, win: Bool? = true, void: Bool = false, deaths: [(Double, String)] = [],
                 goal: GoalState? = nil) -> GameRecord {
    let events = deaths.enumerated().map { n, d in DeathEvent(id: i * 100 + n, time: d.0, killer: d.1) }
    let progress = goal.map {
        GoalProgress(goal: Goal(preset: .deathsBefore14, target: 2), current: 1, state: $0, label: "")
    }
    return GameRecord(id: "g\(i)", date: Date(timeIntervalSince1970: Double(i) * 10_000), champion: "Jinx", role: .adc,
                      win: win, goalResult: progress, deaths: events, durationSec: 1800, isVoid: void)
}
