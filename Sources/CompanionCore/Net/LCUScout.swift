import Foundation

/// loading screen scout, local client only: the gameflow session lists both teams (identity and champion), the
/// ranked stats endpoint answers per puuid. nothing here is stored or logged.
extension LCUClient {
    static let soloQueue = "RANKED_SOLO_5x5"

    public func scoutRoster() async -> ScoutRoster? {
        guard let (data, status) = try? await get("/lol-gameflow/v1/session"), (200..<300).contains(status) else {
            return nil
        }
        async let me = myPuuid()
        async let region = regionCode()
        return Self.decodeScoutRoster(data, mePuuid: await me, region: await region)
    }

    public func scoutRank(puuid: String) async -> ScoutRank? {
        let safe = puuid.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, let (data, status) = try? await get("/lol-ranked/v1/ranked-stats/\(safe)"),
              (200..<300).contains(status) else { return nil }
        return Self.decodeSoloRank(data)
    }

    /// the last 20 games of any player, from the client's own match history (no riot api key).
    public func scoutHistory(puuid: String) async -> [MatchSummary]? {
        let safe = puuid.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty,
              let (data, status) = try? await get("/lol-match-history/v1/products/lol/\(safe)/matches?begIndex=0&endIndex=19"),
              (200..<300).contains(status) else { return nil }
        return Self.decodeMatches(data, puuid: safe)
    }

    private func myPuuid() async -> String? {
        guard let (data, status) = try? await get("/lol-summoner/v1/current-summoner"), (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["puuid"] as? String
    }

    private func regionCode() async -> String? {
        guard let (data, status) = try? await get("/riotclient/region-locale"), (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.opggRegion((object["region"] as? String) ?? (object["webRegion"] as? String))
    }

    /// the client reports "EUW" or a platform id ("EUW1", "LA1"); op.gg wants its own short codes.
    static func opggRegion(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).uppercased(), !raw.isEmpty else { return nil }
        let platforms = ["EUW1": "EUW", "EUN1": "EUNE", "NA1": "NA", "LA1": "LAN", "LA2": "LAS", "OC1": "OCE",
                         "TR1": "TR", "JP1": "JP", "BR1": "BR", "ME1": "ME", "SG2": "SG", "TW2": "TW",
                         "VN2": "VN", "PH2": "PH", "TH2": "TH"]
        return platforms[raw] ?? raw
    }

    // MARK: decoding

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct FlowSession: Decodable {
        var gameData: GameData?
        struct GameData: Decodable {
            var queue: Queue?
            var teamOne: [Lossy<Member>]?
            var teamTwo: [Lossy<Member>]?
        }
        struct Queue: Decodable { var gameMode: String? }
        struct Member: Decodable {
            var championId: Int?
            var puuid: String?
            var summonerName: String?
            var gameName: String?
            var tagLine: String?
            var riotIdGameName: String?
            var riotIdTagLine: String?
            var selectedPosition: String?
        }
    }

    private static let positionOrder = ["TOP": 0, "JUNGLE": 1, "MIDDLE": 2, "BOTTOM": 3, "UTILITY": 4]

    /// both teams of the gameflow session; every field may be missing. nil without any player.
    /// arena (CHERRY) gets one flat list.
    static func decodeScoutRoster(_ data: Data, mePuuid: String?, region: String?) -> ScoutRoster? {
        guard let session = try? JSONDecoder().decode(FlowSession.self, from: data), let game = session.gameData else {
            return nil
        }
        func players(_ list: [Lossy<FlowSession.Member>]?, team: Int) -> [ScoutPlayer] {
            // an entry with neither a champion, an id nor a name has nothing to show.
            let members = (list ?? []).compactMap(\.value).filter {
                ($0.championId ?? 0) > 0 || !($0.puuid ?? "").isEmpty || !($0.summonerName ?? $0.gameName ?? "").isEmpty
            }
            let built = members.enumerated().map { i, m -> ScoutPlayer in
                var name = (m.gameName ?? m.riotIdGameName ?? "").trimmingCharacters(in: .whitespaces)
                var tag = (m.tagLine ?? m.riotIdTagLine ?? "").trimmingCharacters(in: .whitespaces)
                if name.isEmpty, let raw = m.summonerName?.trimmingCharacters(in: .whitespaces) {
                    let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    name = String(parts[0])
                    if parts.count == 2, tag.isEmpty { tag = String(parts[1]) }
                }
                let puuid = m.puuid.flatMap { $0.isEmpty ? nil : $0 }
                return ScoutPlayer(id: puuid ?? "\(team)-\(i)", championKey: max(m.championId ?? 0, 0), gameName: name,
                                   tagLine: tag, puuid: puuid, position: m.selectedPosition.flatMap { $0.isEmpty ? nil : $0 },
                                   isMe: puuid != nil && puuid == mePuuid)
            }
            // stable: roles in lane order when every player has one, else the client's order.
            guard built.allSatisfy({ positionOrder[$0.position?.uppercased() ?? ""] != nil }) else { return built }
            return built.sorted { positionOrder[$0.position!.uppercased()]! < positionOrder[$1.position!.uppercased()]! }
        }
        let one = players(game.teamOne, team: 1)
        let two = players(game.teamTwo, team: 2)
        guard !one.isEmpty || !two.isEmpty else { return nil }

        if game.queue?.gameMode?.uppercased() == "CHERRY" {
            return ScoutRoster(teams: [ScoutTeam(title: "Players", players: one + two)], region: region)
        }
        var teams: [ScoutTeam]
        if one.contains(where: \.isMe) {
            teams = [ScoutTeam(title: "Your team", players: one), ScoutTeam(title: "Enemy team", players: two)]
        } else if two.contains(where: \.isMe) {
            teams = [ScoutTeam(title: "Your team", players: two), ScoutTeam(title: "Enemy team", players: one)]
        } else {
            teams = [ScoutTeam(title: "Blue team", players: one), ScoutTeam(title: "Red team", players: two)]
        }
        teams.removeAll { $0.players.isEmpty }
        return ScoutRoster(teams: teams, region: region)
    }

    private struct RankedStats: Decodable {
        var queues: [Lossy<Entry>]?
        var queueMap: [String: Lossy<Entry>]?
        struct Entry: Decodable {
            var queueType: String?
            var tier: String?
            var division: String?
            var leaguePoints: Int?
            var wins: Int?
            var losses: Int?
        }
    }

    /// the solo/duo entry of a ranked-stats payload. a payload without that entry means unranked; an
    /// unreadable payload is nil.
    static func decodeSoloRank(_ data: Data) -> ScoutRank? {
        guard let stats = try? JSONDecoder().decode(RankedStats.self, from: data),
              stats.queues != nil || stats.queueMap != nil else { return nil }
        let entry = stats.queues?.compactMap(\.value).first { $0.queueType == soloQueue }
            ?? stats.queueMap?[soloQueue]?.value
        guard let entry else { return .unranked }
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces).uppercased(),
                  !s.isEmpty, !["NA", "NONE", "UNRANKED"].contains(s) else { return nil }
            return s
        }
        let tier = clean(entry.tier)
        return ScoutRank(tier: tier, division: tier == nil ? nil : clean(entry.division), lp: max(entry.leaguePoints ?? 0, 0),
                         wins: max(entry.wins ?? 0, 0), losses: max(entry.losses ?? 0, 0))
    }
}
