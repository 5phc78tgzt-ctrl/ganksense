import Foundation

public struct LCUCredentials: Sendable, Equatable {
    public var port: Int
    public var password: String
    public init(port: Int, password: String) {
        self.port = port
        self.password = password
    }

    /// looks for a line containing league client with `--app-port=` and `--remoting-auth-token=`.
    public static func parseProcessArgs(_ s: String) -> LCUCredentials? {
        for line in s.split(whereSeparator: \.isNewline) where line.contains("LeagueClient") {
            var port: Int?
            var token: String?
            for arg in line.split(separator: " ") {
                if arg.hasPrefix("--app-port=") { port = Int(arg.dropFirst("--app-port=".count)) }
                if arg.hasPrefix("--remoting-auth-token=") { token = String(arg.dropFirst("--remoting-auth-token=".count)) }
            }
            if let port, let token, !token.isEmpty { return LCUCredentials(port: port, password: token) }
        }
        return nil
    }

    /// reads the client's port and token from its command line, so no file of the league app is touched.
    public static func discover() -> LCUCredentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "args"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProcessArgs(String(decoding: data, as: UTF8.self))
    }
}

public protocol ClientSource: Sendable {
    func phase() async throws -> GameflowPhase
    func champSelect() async throws -> ChampSelectInfo?
    func recentMatches(count: Int) async throws -> [MatchSummary]
}

/// trusts the league client's self-signed certificate, only for host 127.0.0.1.
final class LCUTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "127.0.0.1", let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

public final class LCUClient: ClientSource, RunePageWriter, ScoutSource, MatchmakingSource {
    private let credentials: LCUCredentials
    private let session: URLSession

    public init(credentials: LCUCredentials) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        self.credentials = credentials
        self.session = URLSession(configuration: cfg, delegate: LCUTrustDelegate(), delegateQueue: nil)
    }

    public init(credentials: LCUCredentials, session: URLSession) {
        self.credentials = credentials
        self.session = session
    }

    public struct HTTPError: Error, Equatable { public let status: Int }

    func get(_ path: String) async throws -> (Data, Int) {
        try await send("GET", path, body: nil)
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> (Data, Int) {
        guard let url = URL(string: "https://127.0.0.1:\(credentials.port)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let auth = Data("riot:\(credentials.password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func phase() async throws -> GameflowPhase {
        let (data, status) = try await get("/lol-gameflow/v1/gameflow-phase")
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
        return Self.decodePhase(data)
    }

    public func champSelect() async throws -> ChampSelectInfo? {
        let (data, status) = try await get("/lol-champ-select/v1/session")
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
        return Self.decodeChampSelect(data)
    }

    /// writes the page into our own "ganksense" rune page and selects it. lists pages and slots fresh on every
    /// call; touches no other page and never deletes (see `RunePageApplier`).
    public func applyRunePage(_ page: RunePage) async -> RuneApplyOutcome {
        guard let payload = RunePageApplier.payload(for: page),
              let body = try? JSONEncoder().encode(payload) else { return .invalidPage }
        do {
            let (pagesData, pagesStatus) = try await get("/lol-perks/v1/pages")
            guard (200..<300).contains(pagesStatus), let pages = RunePageApplier.decodePages(pagesData) else {
                return .failed
            }
            let (inventory, inventoryStatus) = try await get("/lol-perks/v1/inventory")
            let owned = (200..<300).contains(inventoryStatus) ? RunePageApplier.decodeOwnedCount(inventory) : nil

            let id: Int
            switch RunePageApplier.plan(pages: pages, ownedPageCount: owned) {
            case .noFreeSlot:
                return .noFreeSlot
            case .update(let existing):
                let (_, status) = try await send("PUT", "/lol-perks/v1/pages/\(existing)", body: body)
                guard (200..<300).contains(status) else { return .failed }
                id = existing
            case .create:
                let (data, status) = try await send("POST", "/lol-perks/v1/pages", body: body)
                guard (200..<300).contains(status), let created = RunePageApplier.decodeID(data) else { return .failed }
                id = created
            }
            let (_, status) = try await send("PUT", "/lol-perks/v1/currentpage", body: Data(String(id).utf8))
            return (200..<300).contains(status) ? .applied : .failed
        } catch {
            return .failed
        }
    }

    public func recentMatches(count: Int) async throws -> [MatchSummary] {
        let end = max(count, 1) - 1
        let (data, status) = try await get("/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=\(end)")
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
        return Self.decodeMatches(data)
    }


    public func queueSearch() async -> QueueSearch? {
        guard let (data, status) = try? await get("/lol-matchmaking/v1/search"), (200..<300).contains(status) else {
            return nil
        }
        return Self.decodeQueueSearch(data)
    }

    public func acceptReadyCheck() async -> Bool {
        guard let (_, status) = try? await send("POST", "/lol-matchmaking/v1/ready-check/accept", body: nil) else {
            return false
        }
        return (200..<300).contains(status)
    }

    private struct Search: Decodable {
        var timeInQueue: Double?
        var estimatedQueueTime: Double?
        var readyCheck: ReadyCheck?
        struct ReadyCheck: Decodable {
            var state: String?
            var playerResponse: String?
        }
    }

    static func decodeQueueSearch(_ data: Data) -> QueueSearch? {
        guard let s = try? JSONDecoder().decode(Search.self, from: data), let time = s.timeInQueue else { return nil }
        let open = s.readyCheck?.state == "InProgress"
        return QueueSearch(timeInQueue: max(time, 0), estimate: s.estimatedQueueTime.flatMap { $0 > 0 ? $0 : nil },
                           readyCheckResponse: open ? s.readyCheck?.playerResponse : nil)
    }

    static func decodePhase(_ data: Data) -> GameflowPhase {
        (try? JSONDecoder().decode(GameflowPhase.self, from: data)) ?? .unknown
    }

    private struct CSSession: Decodable {
        var localPlayerCellId: Int?
        var myTeam: [Member]?
        var theirTeam: [Member]?
        var benchEnabled: Bool?
        var bans: Bans?
        struct Member: Decodable {
            var cellId: Int?
            var championId: Int?
            var championPickIntent: Int?
            var assignedPosition: String?
        }
        struct Bans: Decodable {
            var myTeamBans: [Int]?
            var theirTeamBans: [Int]?
        }
    }

    static func decodeChampSelect(_ data: Data) -> ChampSelectInfo? {
        guard let s = try? JSONDecoder().decode(CSSession.self, from: data),
              let cell = s.localPlayerCellId,
              let me = s.myTeam?.first(where: { $0.cellId == cell }) else { return nil }
        let picked = me.championId ?? 0
        let intent = me.championPickIntent ?? 0
        let key = picked != 0 ? picked : (intent != 0 ? intent : nil)
        let role = me.assignedPosition.flatMap { Role(lcuPosition: $0) }
        // the lane opponent: the enemy pick in my position, once revealed.
        let laner = role.flatMap { role in
            s.theirTeam?.first { $0.assignedPosition.flatMap { Role(lcuPosition: $0) } == role && ($0.championId ?? 0) > 0 }?
                .championId
        }
        // normal draft reports no enemy positions: hand over the locked picks so the lane can be inferred.
        let enemyLocked = (s.theirTeam ?? []).compactMap { ($0.championId ?? 0) > 0 ? $0.championId : nil }
        let hasEnemyPositions = (s.theirTeam ?? []).contains { $0.assignedPosition.flatMap { Role(lcuPosition: $0) } != nil }
        // bans and locked picks: champions nobody can pick any more.
        var gone = Set<Int>()
        for id in (s.bans?.myTeamBans ?? []) + (s.bans?.theirTeamBans ?? []) where id > 0 { gone.insert(id) }
        for member in (s.myTeam ?? []) + (s.theirTeam ?? []) {
            if let id = member.championId, id > 0 { gone.insert(id) }
        }
        let allies = (s.myTeam ?? []).filter { $0.cellId != cell }.compactMap { m -> Int? in
            let id = (m.championId ?? 0) != 0 ? m.championId : m.championPickIntent
            return (id ?? 0) > 0 ? id : nil
        }
        return ChampSelectInfo(championKey: key, role: role, enemyLaner: laner,
                               enemyPicks: hasEnemyPositions ? [] : enemyLocked, unavailable: gone, allies: allies,
                               isDraft: role != nil && s.benchEnabled != true)
    }

    private struct History: Decodable {
        var games: Games?
        struct Games: Decodable { var games: [Game]? }
        struct Game: Decodable {
            var gameId: Int?
            var gameCreation: Double?
            var gameDuration: Int?
            var queueId: Int?
            var participants: [Participant]?
            var participantIdentities: [Identity]?
        }
        struct Participant: Decodable {
            var participantId: Int?
            var championId: Int?
            var stats: Stats?
        }
        struct Identity: Decodable {
            var participantId: Int?
            var player: Player?
            struct Player: Decodable { var puuid: String? }
        }
        struct Stats: Decodable { var win: Bool? }
    }

    /// the games of a match history payload, as seen by `puuid` (the payload's only participant when nil or not
    /// listed).
    static func decodeMatches(_ data: Data, puuid: String? = nil) -> [MatchSummary] {
        guard let h = try? JSONDecoder().decode(History.self, from: data) else { return [] }
        let out: [MatchSummary] = (h.games?.games ?? []).compactMap { g in
            guard let id = g.gameId, let created = g.gameCreation, let dur = g.gameDuration else { return nil }
            let pid = puuid.flatMap { puuid in g.participantIdentities?.first { $0.player?.puuid == puuid }?.participantId }
            let p = pid.flatMap { pid in g.participants?.first { $0.participantId == pid } } ?? g.participants?.first
            return MatchSummary(
                gameId: id,
                start: Date(timeIntervalSince1970: created / 1000),
                durationSec: dur,
                queueId: g.queueId ?? 0,
                win: p?.stats?.win ?? false,
                championKey: p?.championId ?? 0,
                remake: dur < 300
            )
        }
        return out.sorted { $0.start > $1.start }
    }
}
