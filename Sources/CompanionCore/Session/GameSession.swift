import Foundation

/// one game being tracked (main actor only).
@MainActor
final class GameSession {
    let id: String
    let startDate: Date
    let champion: String
    let role: Role?
    let rosterKey: String
    var lastGameTime: Double
    var lastSnapshot: LiveGameSnapshot?
    var deaths: [Int: DeathEvent] = [:]
    var ended = false
    var win: Bool?
    var suspended = false
    var goalLatched: GoalProgress?
    /// last paced-goal reading at or before the goal's deadline (game time, raw value).
    var goalBefore: (t: Double, value: Double)?
    var spikes = SpikeDetector()
    /// enemy power spikes seen live, for the death-cause estimate.
    var spikeLog: [GameContext.Spike] = []
    var jungler = JunglerTracker()
    var base: BaseBuild?
    var baseFetch: Task<Void, Never>?
    var augmentsRequested = false
    var augmentFetch: Task<Void, Never>?

    /// a reconnect can report a slightly earlier game time; a bigger jump back means a new game with the same roster.
    private static let gameTimeRewindTolerance: Double = 120

    init(id: String, startDate: Date, champion: String, role: Role?, rosterKey: String, gameTime: Double) {
        self.id = id
        self.startDate = startDate
        self.champion = champion
        self.role = role
        self.rosterKey = rosterKey
        self.lastGameTime = gameTime
    }

    /// true when a snapshot with this roster and game time is still this game.
    func continues(roster: String, gameTime: Double) -> Bool {
        rosterKey == roster && gameTime >= lastGameTime - Self.gameTimeRewindTolerance
    }

    /// takes a ready summoner's rift snapshot of this game: deaths are keyed by event id, so replays never double-count.
    func ingest(_ s: LiveGameSnapshot, gameTime: Double) {
        suspended = false
        lastSnapshot = s
        lastGameTime = gameTime
        for death in DeathRecorder.deaths(in: s) where deaths[death.id] == nil {
            deaths[death.id] = death
        }
        guard let end = s.events.last(where: { $0.name == "GameEnd" }) else { return }
        ended = true
        switch end.result?.lowercased() {
        case "win": win = true
        case "lose", "loss": win = false
        default: break
        }
    }

    func logSpikes(_ alerts: [SpikeAlert], at time: Double) {
        for alert in alerts {
            let prefix = "\(alert.champion) · "
            let detail = alert.text.hasPrefix(prefix) ? String(alert.text.dropFirst(prefix.count)) : alert.text
            spikeLog.append(GameContext.Spike(time: time, champion: alert.champion, detail: detail))
        }
    }

    /// the stored result of this game. void games (remakes) get no goal result.
    func makeRecord(finalSnapshot last: LiveGameSnapshot, goal: Goal?, catalog: ItemCatalog?) -> GameRecord {
        let duration = last.gameData?.gameTime ?? lastGameTime
        let isVoid = duration < Coordinator.voidThreshold
        let goalResult: GoalProgress? = isVoid ? nil : goalLatched ?? goal.map {
            GoalTracker.evaluate($0, snapshot: last, catalog: catalog, final: true, before: goalBefore)
        }
        let sortedDeaths = deaths.values.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        return GameRecord(id: id, date: startDate, champion: champion, role: role, win: win,
                          goalResult: goalResult, deaths: sortedDeaths, durationSec: duration, isVoid: isVoid,
                          context: GameContext(snapshot: last, spikes: spikeLog))
    }
}
