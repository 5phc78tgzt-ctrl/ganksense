import Foundation

/// champion pool of one player, on demand only (the scout row the user opens). the riot id goes to op.gg for
/// that one request and is never cached, on disk or in memory beyond the game.
extension OPGGClient: ChampionPoolSource {
    static let poolFields = ["data.summoner.most_champions.champion_stats[].{champion_name,id,play,win,lose}"]
    static let poolSize = 3

    public func championPool(gameName: String, tagLine: String, region: String) async -> [PoolChampion]? {
        let arguments: [String: Any] = [
            "game_name": gameName, "tag_line": tagLine, "region": region,
            "desired_output_fields": Self.poolFields,
        ]
        guard let text = await fetchText(tool: "lol_get_summoner_profile", arguments: arguments),
              let parsed = try? OPGGParser.parse(text) else { return nil }
        return Self.pool(from: parsed.root, headers: parsed.headers)
    }

    /// the most played champions (this season's ranked games), most games first. nil when the shape is unknown.
    static func pool(from root: OPGGValue, headers: [String: [String]]) -> [PoolChampion]? {
        guard let rootRecord = Record(root, headers),
              let data = rootRecord["data"].flatMap({ Record($0, headers) }),
              let summoner = data["summoner"].flatMap({ Record($0, headers) }),
              let most = summoner["most_champions"].flatMap({ Record($0, headers) }),
              case let .array(rows)? = most["champion_stats"] else { return nil }
        var out: [PoolChampion] = []
        for row in rows {
            guard let r = Record(row, headers),
                  let name = r["champion_name"].flatMap(string), !name.isEmpty,
                  let play = r["play"].flatMap(int), play > 0,
                  let win = r["win"].flatMap(int), win >= 0, win <= play else { continue }
            out.append(PoolChampion(name: name, games: play, wins: win))
        }
        out.sort { ($1.games, $0.name) < ($0.games, $1.name) }
        return Array(out.prefix(poolSize))
    }
}
