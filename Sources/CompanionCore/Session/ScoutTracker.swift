import Foundation
import Observation

/// loading screen scout: both teams of the running game with solo/duo ranks, from the local client only. fetched
/// once per game when the client reports it in progress (one retry later if the first try came up short), never
/// per poll. champion pools come from op.gg only when a row is opened. everything lives in memory and is dropped
/// when the game ends: no riot id is ever written to disk or to a log.
@MainActor @Observable
public final class ScoutTracker {
    struct Env {
        var scout: ScoutSource?
        var pool: ChampionPoolSource?
        var poolEnabled: Bool
        var sleep: @Sendable (Duration) async throws -> Void
    }

    public private(set) var board: ScoutBoard?
    /// champion pools of the rows opened this game, by player id.
    public private(set) var pools: [String: ScoutPool] = [:]

    static let retryDelay: Duration = .seconds(15)

    @ObservationIgnored private var started = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var poolTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// one client poll. only the first in-progress poll of a game does any work.
    func phase(_ p: GameflowPhase, env: Env) {
        switch p {
        case .inProgress: begin(env)
        case .gameStart, .reconnect, .unknown: break
        default: reset()
        }
    }

    /// the game ended: drop the data but keep the once-per-game latch (the client may still report in progress).
    func clearData() {
        task?.cancel(); task = nil
        for t in poolTasks.values { t.cancel() }
        poolTasks = [:]
        if board != nil { board = nil }
        if !pools.isEmpty { pools = [:] }
    }

    /// a new game may scout again.
    func reset() {
        clearData()
        started = false
    }

    /// fixed preview data (debug popover preview).
    public func showPreview(_ board: ScoutBoard, pools: [String: ScoutPool] = [:]) {
        started = true
        self.board = board
        self.pools = pools
    }

    private func begin(_ env: Env) {
        guard !started, let source = env.scout else { return }
        started = true
        let sleep = env.sleep
        task = Task { [weak self] in
            for attempt in 0..<2 {
                if attempt > 0 {
                    do { try await sleep(Self.retryDelay) } catch { return }
                }
                guard !Task.isCancelled, let self else { return }
                if await self.attempt(source) { break }
            }
            await self?.loadFlags(source)
        }
    }

    /// recent games of every player, then the flags. runs once, after the ranks (which show first).
    private func loadFlags(_ source: ScoutSource) async {
        guard let puuids = board?.players.compactMap(\.puuid), !puuids.isEmpty else { return }
        var histories: [String: [MatchSummary]] = [:]
        await withTaskGroup(of: (String, [MatchSummary]?).self) { group in
            for puuid in puuids { group.addTask { (puuid, await source.scoutHistory(puuid: puuid)) } }
            for await (puuid, games) in group { if let games { histories[puuid] = games } }
        }
        guard !Task.isCancelled, let current = board else { return }
        let flagged = ScoutFlags.compute(board: current, histories: histories)
        if flagged != current { board = flagged }
    }

    /// true when the board is complete: a roster, and a rank for every player the client gave an id for.
    private func attempt(_ source: ScoutSource) async -> Bool {
        var current = board
        if current == nil {
            guard let roster = await source.scoutRoster(), !Task.isCancelled else { return false }
            current = ScoutBoard(teams: roster.teams, region: roster.region)
        }
        guard var next = current else { return false }
        let missing = next.players.filter { $0.rank == nil }.compactMap(\.puuid)
        var ranks: [String: ScoutRank] = [:]
        await withTaskGroup(of: (String, ScoutRank?).self) { group in
            for puuid in missing { group.addTask { (puuid, await source.scoutRank(puuid: puuid)) } }
            for await (puuid, rank) in group { if let rank { ranks[puuid] = rank } }
        }
        guard !Task.isCancelled else { return false }
        for t in next.teams.indices {
            for p in next.teams[t].players.indices {
                if let puuid = next.teams[t].players[p].puuid, let rank = ranks[puuid] { next.teams[t].players[p].rank = rank }
            }
        }
        board = next
        return next.players.allSatisfy { $0.puuid == nil || $0.rank != nil }
    }

    /// loads one player's champion pool from op.gg (a row was opened). cached for the game; a failed lookup can
    /// be retried by opening the row again.
    func loadPool(playerID: String, env: Env) {
        guard env.poolEnabled, let source = env.pool, let board,
              let player = board.players.first(where: { $0.id == playerID }),
              pools[playerID] == nil || pools[playerID] == .unavailable, poolTasks[playerID] == nil else { return }
        guard player.canLookUpPool, let region = board.region, !region.isEmpty else {
            pools[playerID] = .unavailable
            return
        }
        pools[playerID] = .loading
        let name = player.gameName, tag = player.tagLine
        poolTasks[playerID] = Task { [weak self] in
            let pool = await source.championPool(gameName: name, tagLine: tag, region: region)
            guard !Task.isCancelled, let self else { return }
            self.poolTasks[playerID] = nil
            self.pools[playerID] = pool.map(ScoutPool.loaded) ?? .unavailable
        }
    }
}
