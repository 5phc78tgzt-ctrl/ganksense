import Foundation
import CompanionCore

/// the production client source: discovers league client credentials lazily, off the main actor, and caches
/// the connection until a request fails or the client quits (reset()).
///
/// coordinator calls makeclient on the main actor every client tick while it has no client, so handing it
/// this one shared actor keeps that call allocation-free; the expensive part (credential discovery, which
/// runs /bin/ps) runs here, at most once per discovery interval.
actor LCUConnection: ClientSource {
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
final class CurrentPatchOPGG: BaseBuildSource {
    private let cacheDir: URL
    private let patch: @Sendable () async -> String?

    init(cacheDir: URL, patch: @escaping @Sendable () async -> String?) {
        self.cacheDir = cacheDir
        self.patch = patch
    }

    func baseBuild(championID: String, role: Role) async -> BaseBuild? {
        let p = await patch() ?? "unknown"
        return await OPGGClient(cacheDir: cacheDir, patch: p).baseBuild(championID: championID, role: role)
    }
}
