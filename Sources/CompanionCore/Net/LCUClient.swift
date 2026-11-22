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

public final class LCUClient: ClientSource {
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

    private func get(_ path: String) async throws -> (Data, Int) {
        guard let url = URL(string: "https://127.0.0.1:\(credentials.port)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        let auth = Data("riot:\(credentials.password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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

    public func recentMatches(count: Int) async throws -> [MatchSummary] {
        let end = max(count, 1) - 1
        let (data, status) = try await get("/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=\(end)")
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
        return Self.decodeMatches(data)
    }


    static func decodePhase(_ data: Data) -> GameflowPhase {
        (try? JSONDecoder().decode(GameflowPhase.self, from: data)) ?? .unknown
    }

    private struct CSSession: Decodable {
        var localPlayerCellId: Int?
        var myTeam: [Member]?
        struct Member: Decodable {
            var cellId: Int?
            var championId: Int?
            var championPickIntent: Int?
            var assignedPosition: String?
        }
    }

    static func decodeChampSelect(_ data: Data) -> ChampSelectInfo? {
        guard let s = try? JSONDecoder().decode(CSSession.self, from: data),
              let cell = s.localPlayerCellId,
              let me = s.myTeam?.first(where: { $0.cellId == cell }) else { return nil }
        let picked = me.championId ?? 0
        let intent = me.championPickIntent ?? 0
        let key = picked != 0 ? picked : (intent != 0 ? intent : nil)
        return ChampSelectInfo(championKey: key, role: me.assignedPosition.flatMap { Role(lcuPosition: $0) })
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
        }
        struct Participant: Decodable {
            var championId: Int?
            var stats: Stats?
        }
        struct Stats: Decodable { var win: Bool? }
    }

    static func decodeMatches(_ data: Data) -> [MatchSummary] {
        guard let h = try? JSONDecoder().decode(History.self, from: data) else { return [] }
        let out: [MatchSummary] = (h.games?.games ?? []).compactMap { g in
            guard let id = g.gameId, let created = g.gameCreation, let dur = g.gameDuration else { return nil }
            let p = g.participants?.first
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
