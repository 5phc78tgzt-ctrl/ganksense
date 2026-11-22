import Foundation

private struct FlexInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else { value = nil }
    }
}

public struct DDItem: Decodable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let description: String
    public let plaintext: String?
    public let from: [Int]
    public let into: [Int]
    public let goldTotal: Int
    public let purchasable: Bool
    public let tags: [String]
    public let onSummonersRift: Bool
    public let stats: [String: Double]
    public let depth: Int
    public let inStore: Bool
    public let requiredChampion: String?

    public init(id: Int, name: String, description: String = "", plaintext: String? = nil,
                from: [Int] = [], into: [Int] = [], goldTotal: Int = 0, purchasable: Bool = true,
                tags: [String] = [], onSummonersRift: Bool = true, stats: [String: Double] = [:],
                depth: Int = 1, inStore: Bool = true, requiredChampion: String? = nil) {
        self.id = id; self.name = name; self.description = description; self.plaintext = plaintext
        self.from = from; self.into = into; self.goldTotal = goldTotal; self.purchasable = purchasable
        self.tags = tags; self.onSummonersRift = onSummonersRift; self.stats = stats
        self.depth = depth; self.inStore = inStore; self.requiredChampion = requiredChampion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, plaintext, from, into, gold, tags, maps, stats, depth, inStore, requiredChampion
    }
    private struct Gold: Decodable {
        var total: Int?
        var purchasable: Bool?
    }

    /// `id` is not part of the payload (it is the dictionary key); it defaults to 0 and is injected by the catalog.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        plaintext = try? c.decode(String.self, forKey: .plaintext)
        from = ((try? c.decode([FlexInt].self, forKey: .from)) ?? []).compactMap(\.value)
        into = ((try? c.decode([FlexInt].self, forKey: .into)) ?? []).compactMap(\.value)
        let gold = try? c.decode(Gold.self, forKey: .gold)
        goldTotal = gold?.total ?? 0
        purchasable = gold?.purchasable ?? true
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        let maps = (try? c.decode([String: Bool].self, forKey: .maps)) ?? [:]
        onSummonersRift = maps["11"] ?? false
        stats = (try? c.decode([String: Double].self, forKey: .stats)) ?? [:]
        depth = (try? c.decode(Int.self, forKey: .depth)) ?? 1
        inStore = (try? c.decode(Bool.self, forKey: .inStore)) ?? true
        let rc = try? c.decode(String.self, forKey: .requiredChampion)
        requiredChampion = (rc?.isEmpty ?? true) ? nil : rc
    }

    func withID(_ newID: Int) -> DDItem {
        DDItem(id: newID, name: name, description: description, plaintext: plaintext, from: from, into: into,
               goldTotal: goldTotal, purchasable: purchasable, tags: tags, onSummonersRift: onSummonersRift,
               stats: stats, depth: depth, inStore: inStore, requiredChampion: requiredChampion)
    }
}

extension DDItem {
    public var isCompleted: Bool {
        if tags.contains("Boots") { return depth >= 2 }
        if tags.contains("Consumable") || tags.contains("Trinket") { return false }
        // not `depth >= 3`: some legendaries (infinity edge in 16.23) report depth 2.
        return into.isEmpty && goldTotal >= 2200
    }
}

public struct ItemCatalog: Sendable {
    public let version: String
    public let items: [Int: DDItem]

    public init(version: String, items: [Int: DDItem]) {
        self.version = version
        self.items = items
    }

    public func item(_ id: Int) -> DDItem? { items[id] }

    /// case-insensitive name lookup; variants (extra ids >= 100000) lose to the lowest plain id.
    public func item(named name: String) -> DDItem? {
        let key = name.lowercased()
        return items.values.filter { $0.name.lowercased() == key }.min { $0.id < $1.id }
    }

    /// sr, purchasable, in store, not champion-specific; id >= 100000 variants only when no plain variant shares the name.
    public var shopItems: [DDItem] {
        let plainNames = Set(items.values.filter { $0.id < 100_000 }.map(\.name))
        return items.values
            .filter { $0.onSummonersRift && $0.purchasable && $0.inStore && $0.requiredChampion == nil }
            .filter { $0.id < 100_000 || !plainNames.contains($0.name) }
            .sorted { $0.id < $1.id }
    }

    private struct File: Decodable {
        var data: [String: DDItem]
    }

    public static func decode(_ data: Data, version: String) throws -> ItemCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        var items: [Int: DDItem] = [:]
        for (k, v) in file.data {
            guard let id = Int(k) else { continue }
            items[id] = v.withID(id)
        }
        return ItemCatalog(version: version, items: items)
    }
}

public struct DDChampion: Decodable, Sendable {
    public let id: String
    public let key: Int
    public let name: String
    public let tags: [String]
    public let attack: Int
    public let magic: Int
    public let defense: Int

    public init(id: String, key: Int, name: String, tags: [String] = [], attack: Int = 0, magic: Int = 0, defense: Int = 0) {
        self.id = id; self.key = key; self.name = name; self.tags = tags
        self.attack = attack; self.magic = magic; self.defense = defense
    }

    private enum CodingKeys: String, CodingKey { case id, key, name, tags, info }
    private struct Info: Decodable { var attack: Int?; var magic: Int?; var defense: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let i = try? c.decode(Int.self, forKey: .key) { key = i }
        else if let s = try? c.decode(String.self, forKey: .key), let i = Int(s) { key = i }
        else { key = 0 }
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        let info = try? c.decode(Info.self, forKey: .info)
        attack = info?.attack ?? 0
        magic = info?.magic ?? 0
        defense = info?.defense ?? 0
    }
}

public struct ChampionCatalog: Sendable {
    public let version: String
    public let champions: [DDChampion]
    private let byID: [String: DDChampion]
    private let byKey: [Int: DDChampion]
    private let byNormalized: [String: DDChampion]

    public init(version: String, champions: [DDChampion]) {
        self.version = version
        self.champions = champions
        byID = Dictionary(champions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byKey = Dictionary(champions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var n: [String: DDChampion] = [:]
        for c in champions {
            n[Self.normalize(c.name)] = n[Self.normalize(c.name)] ?? c
            n[Self.normalize(c.id)] = n[Self.normalize(c.id)] ?? c
        }
        byNormalized = n
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public func champion(id: String) -> DDChampion? { byID[id] }
    public func champion(key: Int) -> DDChampion? { byKey[key] }
    public func champion(displayName: String) -> DDChampion? { byNormalized[Self.normalize(displayName)] }

    private struct File: Decodable { var data: [String: DDChampion] }

    public static func decode(_ data: Data, version: String) throws -> ChampionCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        return ChampionCatalog(version: version, champions: file.data.values.sorted { $0.id < $1.id })
    }
}
