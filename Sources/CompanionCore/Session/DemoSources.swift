import Foundation
import Synchronization

/// one step of the demo game as the live client would serve it.
public enum DemoStep: Sendable, Equatable {
    /// loading screen: the api answers but has no players yet (live client not ready error).
    case notReady
    case snapshot(LiveGameSnapshot)
}

/// shared script behind the demo live and client sources.
///
/// time is virtual and advanced by polling, not by the wall clock: every `fetch()` is worth
/// the coordinator's live poll interval (1 s) and every `phase()` its client poll interval (2 s); the script
/// position is the larger of the two totals. so the demo runs at real speed under the real coordinator and
/// as fast as the injected test clock allows in tests, with the same, deterministic arc.
///
/// schedule (each slot 3 s by default): lobby · champ select · game steps (phase in progress) ·
/// 2 slots end of game · lobby forever. the live source throws not running outside the game slots.
public final class DemoTimeline: Sendable {
    public let steps: [DemoStep]
    public let stepDuration: Duration

    static let lobbySlots = 1
    static let champSelectSlots = 1
    static let endOfGameSlots = 2

    private struct State {
        var liveCalls = 0
        var clientCalls = 0
        var servedGameEnd = false
    }
    private let state = Mutex(State())

    public init(steps: [DemoStep], stepDuration: Duration = .seconds(3)) {
        self.steps = steps
        self.stepDuration = stepDuration
    }

    /// `demo_timeline.json` from the bundle; an empty script (game never starts) if it cannot be read.
    public static func bundled(stepDuration: Duration = .seconds(3)) -> DemoTimeline {
        DemoTimeline(steps: (try? loadBundledSteps()) ?? [], stepDuration: stepDuration)
    }

    /// true once the step carrying the game end event (the last step) has been served.
    public var gameEnded: Bool { state.withLock { $0.servedGameEnd } }


    enum Slot: Equatable { case lobby, champSelect, game(Int), endOfGame, after }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func slot(at t: Double) -> Slot {
        let step = max(Self.seconds(stepDuration), 0.001)
        var i = Int(t / step)
        if i < Self.lobbySlots { return .lobby }
        i -= Self.lobbySlots
        if i < Self.champSelectSlots { return .champSelect }
        i -= Self.champSelectSlots
        if i < steps.count { return .game(i) }
        i -= steps.count
        return i < Self.endOfGameSlots ? .endOfGame : .after
    }

    private func now(_ s: State) -> Double {
        max(Double(s.liveCalls) * Self.seconds(Coordinator.livePollInterval),
            Double(s.clientCalls) * Self.seconds(Coordinator.clientPollInterval))
    }

    func nextLive() -> DemoStep? {
        state.withLock { s in
            let current = slot(at: now(s))
            s.liveCalls += 1
            guard case .game(let i) = current else { return nil }
            if i == steps.count - 1 { s.servedGameEnd = true }
            return steps[i]
        }
    }

    func nextPhase() -> GameflowPhase {
        state.withLock { s in
            let current = slot(at: now(s))
            s.clientCalls += 1
            switch current {
            case .lobby, .after: return .lobby
            case .champSelect: return .champSelect
            case .game: return .inProgress
            case .endOfGame: return .endOfGame
            }
        }
    }


    private struct File: Decodable {
        var base: String
        var steps: [Step]
    }

    private struct Step: Decodable {
        var loading: Bool?
        var t: Double?
        var gold: Double?
        var players: [String: Patch]?
        var events: [GameEvent]?
    }

    private struct Patch: Decodable {
        var level: Int?
        var items: [Int]?
        var kda: [Int]?
        var cs: Int?
        var dead: Bool?
        var respawn: Double?
    }

    static func fixtureData(_ name: String) throws -> Data {
        guard let url = CoreResources.bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }

    /// expands the compact patch format into full snapshots (patches are cumulative).
    static func loadBundledSteps() throws -> [DemoStep] {
        let file = try JSONDecoder().decode(File.self, from: fixtureData("demo_timeline"))
        var current = try JSONDecoder().decode(LiveGameSnapshot.self, from: fixtureData(file.base))
        current.events = []
        var out: [DemoStep] = []
        for step in file.steps {
            if step.loading == true { out.append(.notReady); continue }
            if let t = step.t { current.gameData?.gameTime = t }
            if let g = step.gold { current.activePlayer?.currentGold = g }
            for (name, p) in step.players ?? [:] {
                guard let i = current.allPlayers.firstIndex(where: { $0.championName == name }) else { continue }
                var pl = current.allPlayers[i]
                if let l = p.level { pl.level = l }
                if let items = p.items { pl.items = items.enumerated().map { PlayerItem(itemID: $1, slot: $0) } }
                if let kda = p.kda, kda.count == 3 {
                    pl.scores.kills = kda[0]; pl.scores.deaths = kda[1]; pl.scores.assists = kda[2]
                }
                if let cs = p.cs { pl.scores.creepScore = cs }
                if let d = p.dead { pl.isDead = d }
                if let r = p.respawn { pl.respawnTimer = r }
                current.allPlayers[i] = pl
            }
            if let me = current.me, let lvl = step.players?[me.championName]?.level { current.activePlayer?.level = lvl }
            current.events += step.events ?? []
            out.append(.snapshot(current))
        }
        return out
    }
}

/// replays the demo timeline as the live client api.
public struct DemoLiveSource: LiveGameSource {
    public let timeline: DemoTimeline

    public init(timeline: DemoTimeline) { self.timeline = timeline }
    public init(stepDuration: Duration = .seconds(3)) { self.init(timeline: .bundled(stepDuration: stepDuration)) }

    public func fetch() async throws -> LiveGameSnapshot {
        switch timeline.nextLive() {
        case .snapshot(let s)?: return s
        case .notReady?: throw LiveClientError.notReady
        case nil: throw LiveClientError.notRunning
        }
    }
}

/// league client for the demo: lobby → champ select (jinx, adc) → in progress → end of game → lobby.
/// match history: 4 games today-ish with a 2-loss streak; once the demo game has ended its loss is prepended
/// (3 in a row, so the tilt guard nudges after the demo game).
public struct DemoClientSource: ClientSource {
    public let timeline: DemoTimeline
    public static let jinxKey = 222

    public init(timeline: DemoTimeline) { self.timeline = timeline }
    public init(stepDuration: Duration = .seconds(3)) { self.init(timeline: .bundled(stepDuration: stepDuration)) }

    public func phase() async throws -> GameflowPhase { timeline.nextPhase() }

    public func champSelect() async throws -> ChampSelectInfo? {
        ChampSelectInfo(championKey: Self.jinxKey, role: .adc)
    }

    public func recentMatches(count: Int) async throws -> [MatchSummary] {
        let now = Date()
        func game(_ id: Int, minutesAgo: Double, win: Bool, champ: Int) -> MatchSummary {
            MatchSummary(gameId: id, start: now.addingTimeInterval(-minutesAgo * 60), durationSec: 1800, queueId: 420,
                         win: win, championKey: champ, remake: false)
        }
        var games = [
            game(4, minutesAgo: 50, win: false, champ: Self.jinxKey),
            game(3, minutesAgo: 85, win: false, champ: 51),
            game(2, minutesAgo: 26 * 60, win: true, champ: Self.jinxKey),
            game(1, minutesAgo: 27 * 60, win: true, champ: 21),
        ]
        if timeline.gameEnded {
            games.insert(MatchSummary(gameId: 5, start: now.addingTimeInterval(-16 * 60), durationSec: 900,
                                      queueId: 420, win: false, championKey: Self.jinxKey, remake: false), at: 0)
        }
        return Array(games.prefix(max(0, count)))
    }
}
