public struct SpikeAlert: Sendable, Equatable, Identifiable {
    public var id: String
    public var champion: String
    public var text: String

    public init(id: String, champion: String, text: String) {
        self.id = id; self.champion = champion; self.text = text
    }
}

public struct SpikeDetector: Sendable {
    private struct Seen {
        var level: Int
        /// highest simultaneous count seen per completed item id (so sell/rebuy never re-alerts).
        var items: [Int: Int]
    }

    private var seen: [String: Seen] = [:]
    private var seeded = false
    private static let levelSpikes = [6, 11, 16]

    public init() {}

    public mutating func update(_ snapshot: LiveGameSnapshot, catalog: ItemCatalog) -> [SpikeAlert] {
        let enemies = snapshot.enemies
        // loading screen / unidentified me: do not seed on an empty enemy list.
        guard !enemies.isEmpty else { return [] }
        var alerts: [SpikeAlert] = []

        for enemy in enemies {
            let key = enemy.championName
            let owned = Self.completedCounts(enemy, catalog)
            guard seeded, var prev = seen[key] else {
                seen[key] = Seen(level: enemy.level, items: owned)
                continue
            }

            let ownedTotal = owned.values.reduce(0, +)
            var fresh: [Int] = []
            for id in owned.keys.sorted() {
                let rise = owned[id, default: 0] - prev.items[id, default: 0]
                if rise > 0 { fresh.append(contentsOf: Array(repeating: id, count: rise)) }
            }
            for (k, id) in fresh.enumerated() {
                let ordinal = max(1, ownedTotal - fresh.count + k + 1)
                let name = catalog.item(id)?.name ?? "item"
                alerts.append(SpikeAlert(id: "\(key)-item-\(id)-\(ordinal)", champion: key,
                                         text: "\(key) · \(Self.ordinal(ordinal)) item: \(name)"))
            }
            for (id, n) in owned { prev.items[id] = max(prev.items[id, default: 0], n) }

            for lvl in Self.levelSpikes where prev.level < lvl && enemy.level >= lvl {
                alerts.append(SpikeAlert(id: "\(key)-level-\(lvl)", champion: key, text: "\(key) · level \(lvl)"))
            }
            prev.level = max(prev.level, enemy.level)
            seen[key] = prev
        }
        seeded = true
        return alerts
    }

    /// items that turn into another one once stacked: the upgrade is the same item, not a new spike.
    static let transforms = ["Muramana": "Manamune", "Seraph's Embrace": "Archangel's Staff",
                             "Fimbulwinter": "Winter's Approach"]

    private static func completedCounts(_ p: Player, _ catalog: ItemCatalog) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for it in p.items {
            guard let d = catalog.item(it.itemID), d.isCompleted, !d.tags.contains("Boots") else { continue }
            let id = transforms[d.name].flatMap { catalog.item(named: $0)?.id } ?? it.itemID
            out[id, default: 0] += max(1, it.count)
        }
        return out
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }
}
