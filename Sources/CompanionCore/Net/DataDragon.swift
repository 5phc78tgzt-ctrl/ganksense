import Foundation

public actor DataDragon {
    public enum DDError: Error { case noVersion, badStatus(Int) }

    private let cacheDir: URL
    private let session: URLSession
    private static let base = "https://ddragon.leagueoflegends.com"

    public init(cacheDir: URL, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.cacheDir = cacheDir
        self.session = session
    }

    public func latestVersion() async throws -> String {
        do {
            let data = try await fetch(URL(string: "\(Self.base)/api/versions.json")!)
            let versions = try JSONDecoder().decode([String].self, from: data)
            guard let first = versions.first else { throw DDError.noVersion }
            return first
        } catch {
            if let cached = cachedVersions().first { return cached }
            throw error
        }
    }

    public func items(version: String) async throws -> ItemCatalog {
        let data = try await load(version: version, file: "item.json")
        return try ItemCatalog.decode(data, version: version)
    }

    public func champions(version: String) async throws -> ChampionCatalog {
        let data = try await load(version: version, file: "champion.json")
        return try ChampionCatalog.decode(data, version: version)
    }

    public func icons(version: String) async throws -> IconCatalog {
        try IconCatalog.decode(runes: try await load(version: version, file: "runesReforged.json"),
                               spells: try await load(version: version, file: "summoner.json"), version: version)
    }

    public nonisolated func itemIconURL(id: Int, version: String) -> URL {
        URL(string: "\(Self.base)/cdn/\(version)/img/item/\(id).png")!
    }

    /// square champion portrait; `id` is data dragon's champion id ("MonkeyKing"), not the display name.
    public nonisolated func championIconURL(id: String, version: String) -> URL {
        URL(string: "\(Self.base)/cdn/\(version)/img/champion/\(id).png")!
    }

    /// newest cached version that has both catalogs, decoded.
    public func loadCached() -> (ItemCatalog, ChampionCatalog)? {
        for v in cachedVersions() {
            let dir = cacheDir.appendingPathComponent(v)
            guard let i = try? Data(contentsOf: dir.appendingPathComponent("item.json")),
                  let c = try? Data(contentsOf: dir.appendingPathComponent("champion.json")),
                  let items = try? ItemCatalog.decode(i, version: v),
                  let champs = try? ChampionCatalog.decode(c, version: v) else { continue }
            return (items, champs)
        }
        return nil
    }


    private func load(version: String, file: String) async throws -> Data {
        let local = cacheDir.appendingPathComponent(version).appendingPathComponent(file)
        if let d = try? Data(contentsOf: local) { return d }
        let data = try await fetch(URL(string: "\(Self.base)/cdn/\(version)/data/en_US/\(file)")!)
        // validate before caching so a bad payload never poisons the cache.
        switch file {
        case "item.json": _ = try ItemCatalog.decode(data, version: version)
        case "champion.json": _ = try ChampionCatalog.decode(data, version: version)
        default: _ = try JSONSerialization.jsonObject(with: data)
        }
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: local, options: .atomic)
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DDError.badStatus(http.statusCode)
        }
        return data
    }

    /// cached version directories, newest first (numeric dotted compare).
    private func cachedVersions() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        return names
            .filter { parts($0).count >= 2 && $0.first?.isNumber == true }
            .sorted { parts($1).lexicographicallyPrecedes(parts($0)) }
    }
}
