import Foundation
import CompanionCore

/// the production client source: discovers league client credentials lazily, off the main actor, and caches
/// the connection until a request fails or the client quits (reset()).
///
/// coordinator calls makeclient on the main actor every client tick while it has no client, so handing it
/// this one shared actor keeps that call allocation-free; the expensive part (credential discovery, which
/// runs /bin/ps) runs here, at most once per discovery interval.
actor LCUConnection: ClientSource, RunePageWriter, ScoutSource, MatchmakingSource {
    struct NotConnected: Error {}

    static let discoveryInterval: Duration = .seconds(4)

    private var client: LCUClient?
    private var lastDiscovery: ContinuousClock.Instant?

    func reset() {
        client = nil
        lastDiscovery = nil
    }

    func phase() async throws -> GameflowPhase {
        try await forward { try await $0.phase() }
    }

    func champSelect() async throws -> ChampSelectInfo? {
        try await forward { try await $0.champSelect() }
    }

    func recentMatches(count: Int) async throws -> [MatchSummary] {
        try await forward { try await $0.recentMatches(count: count) }
    }

    func applyRunePage(_ page: RunePage) async -> RuneApplyOutcome {
        guard let c = try? connected() else { return .failed }
        return await c.applyRunePage(page)
    }

    func scoutRoster() async -> ScoutRoster? {
        guard let c = try? connected() else { return nil }
        return await c.scoutRoster()
    }

    func scoutRank(puuid: String) async -> ScoutRank? {
        guard let c = try? connected() else { return nil }
        return await c.scoutRank(puuid: puuid)
    }

    func queueSearch() async -> QueueSearch? {
        guard let c = try? connected() else { return nil }
        return await c.queueSearch()
    }

    func acceptReadyCheck() async -> Bool {
        guard let c = try? connected() else { return false }
        return await c.acceptReadyCheck()
    }

    func scoutHistory(puuid: String) async -> [MatchSummary]? {
        guard let c = try? connected() else { return nil }
        return await c.scoutHistory(puuid: puuid)
    }

    private func forward<T: Sendable>(_ op: (LCUClient) async throws -> T) async throws -> T {
        let c = try connected()
        do {
            return try await op(c)
        } catch {
            if client === c { client = nil }
            throw error
        }
    }

    private func connected() throws -> LCUClient {
        if let client { return client }
        let now = ContinuousClock.now
        if let last = lastDiscovery, now - last < Self.discoveryInterval { throw NotConnected() }
        lastDiscovery = now
        guard let creds = LCUCredentials.discover() else { throw NotConnected() }
        let c = LCUClient(credentials: creds)
        client = c
        return c
    }
}

/// op.gg with the patch taken from the coordinator's current item catalog at call time (opggclient keys its
/// cache by patch, and the patch is only known after data dragon loads).
final class CurrentPatchOPGG: BaseBuildSource, ChampSelectAdviceSource, ChampionPoolSource {
    private let cacheDir: URL
    private let patch: @Sendable () async -> String?

    init(cacheDir: URL, patch: @escaping @Sendable () async -> String?) {
        self.cacheDir = cacheDir
        self.patch = patch
    }

    func baseBuild(championID: String, role: Role, aram: Bool) async -> BaseBuild? {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).baseBuild(championID: championID, role: role, aram: aram)
    }

    func augments(championKey: Int) async -> [AramAugment] {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).augments(championKey: championKey)
    }

    func advice(championID: String, role: Role) async -> ChampionAdvice? {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).advice(championID: championID, role: role)
    }

    func matchupTip(championID: String, championName: String, opponentID: String, opponentName: String,
                    role: Role) async -> MatchupTip? {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).matchupTip(
            championID: championID, championName: championName, opponentID: opponentID,
            opponentName: opponentName, role: role)
    }

    func championPool(gameName: String, tagLine: String, region: String) async -> [PoolChampion]? {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).championPool(gameName: gameName, tagLine: tagLine,
                                                                           region: region)
    }
}
