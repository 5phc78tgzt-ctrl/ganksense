import Foundation

public struct ThreatProfile: Sendable, Equatable {
    /// 0…1 share of enemy damage that is physical, weighted by how fed each enemy is.
    public var adShare: Double
    public var healing: Double
    /// highest per-enemy item armor relative to the expected value for game time, 0…2.
    public var armorStack: Double
    /// highest per-enemy item mr relative to the expected value for game time, 0…2.
    public var mrStack: Double
    public var critCarry: Bool
    public var heavyCC: Bool
    public var burstAssassins: [String]
    public var shields: Double
    public var fedEnemies: [String]
    public var reasons: [CounterCategory: [String]]

    public init(adShare: Double = 0.5, healing: Double = 0, armorStack: Double = 0, mrStack: Double = 0,
                critCarry: Bool = false, heavyCC: Bool = false, burstAssassins: [String] = [],
                shields: Double = 0, fedEnemies: [String] = [], reasons: [CounterCategory: [String]] = [:]) {
        self.adShare = adShare; self.healing = healing; self.armorStack = armorStack; self.mrStack = mrStack
        self.critCarry = critCarry; self.heavyCC = heavyCC; self.burstAssassins = burstAssassins
        self.shields = shields; self.fedEnemies = fedEnemies; self.reasons = reasons
    }

    public static let sustainChampions: Set<String> = [
        "Aatrox", "Soraka", "Vladimir", "Swain", "Sylas", "Warwick", "Fiddlesticks", "Yuumi", "Sona", "Nami",
        "DrMundo", "Olaf", "Briar", "Illaoi", "Volibear", "Trundle", "Nasus", "Maokai", "Zac", "Taric",
        "Seraphine", "Milio", "Senna", "Gwen", "Kayn", "Renekton", "Belveth", "Fiora", "Irelia", "Samira",
    ]

    public static let shieldChampions: Set<String> = [
        "Janna", "Lulu", "Karma", "Orianna", "Ivern", "Lux", "Milio", "Yuumi", "Taric", "Seraphine",
        "Shen", "Sett", "Rumble", "Rakan", "Renata", "Morgana", "Sona",
    ]

    public static let ccChampions: Set<String> = [
        "Leona", "Nautilus", "Amumu", "Sejuani", "Malphite", "Morgana", "Lissandra", "Sion", "Rell", "Thresh",
        "Blitzcrank", "Zac", "Maokai", "Ornn", "Rammus", "Skarner", "Alistar", "Annie", "Galio", "JarvanIV",
        "Vi", "Ashe", "Neeko", "Zyra", "Braum", "Poppy", "Nunu", "MonkeyKing", "Cassiopeia", "Leblanc",
    ]

    /// sustain keystones: conqueror, grasp of the undying, fleet footwork (rune ids, not item ids).
    public static let sustainKeystones: Set<Int> = [8010, 8437, 8021]

    public static let shieldItems: Set<String> = [
        "Moonstone Renewer", "Locket of the Iron Solari", "Echoes of Helia", "Redemption",
    ]

    public static func analyze(enemies: [Player], catalog: ItemCatalog, champions: ChampionCatalog,
                               gameTime: Double) -> ThreatProfile {
        let classifier = ItemClassifier(catalog: catalog)
        return analyze(enemies: enemies, catalog: catalog, champions: champions, gameTime: gameTime,
                       classifier: classifier)
    }

    static func analyze(enemies: [Player], catalog: ItemCatalog, champions: ChampionCatalog,
                        gameTime: Double, classifier: ItemClassifier) -> ThreatProfile {
        var p = ThreatProfile()
        guard !enemies.isEmpty else { return p }

        let expectedResist = 20 + max(0, gameTime) / 60 * 4
        var adWeighted = 0.0, weightSum = 0.0
        var healingParts: [(name: String, value: Double)] = []
        var shieldParts: [(name: String, value: Double)] = []
        var armorParts: [(name: String, ratio: Double, value: Int)] = []
        var mrParts: [(name: String, ratio: Double, value: Int)] = []
        var critCarries: [String] = []
        var ccNames: [String] = []
        var assassins: [(name: String, label: String)] = []

        let allKills = enemies.map(\.scores.kills)
        let avgKills = Double(allKills.reduce(0, +)) / Double(enemies.count)

        for enemy in enemies {
            let champ = champions.champion(id: enemy.championID) ?? champions.champion(displayName: enemy.championName)
            let name = champ?.name ?? enemy.championName
            let id = champ?.id ?? enemy.championID
            // unknown item ids (new patch) are skipped entirely.
            let items = enemy.items.compactMap { catalog.item($0.itemID) }

            let (blend, weight) = damageBlend(champ: champ, items: items, kills: enemy.scores.kills,
                                              classifier: classifier)
            adWeighted += blend * weight
            weightSum += weight

            let heal = healingValue(id: id, items: items, keystone: enemy.runes?.keystone?.id)
            if heal > 0 { healingParts.append((name, heal)) }

            let shield = shieldValue(id: id, items: items)
            if shield > 0 { shieldParts.append((name, shield)) }

            // resist stacking (item stats only; base stats of other players are not in the live data).
            let armor = items.reduce(0.0) { $0 + ($1.stats["FlatArmorMod"] ?? 0) }
            let mr = items.reduce(0.0) { $0 + ($1.stats["FlatSpellBlockMod"] ?? 0) }
            armorParts.append((name, armor / expectedResist, Int(armor.rounded())))
            mrParts.append((name, mr / expectedResist, Int(mr.rounded())))

            if items.filter({ ($0.stats["FlatCritChanceMod"] ?? 0) > 0 }).count >= 2 { critCarries.append(name) }
            if ccChampions.contains(id) || (champ?.tags.first == "Tank") { ccNames.append(name) }
            let completed = items.filter { CounterBuildEngine.isFinished($0) && !$0.tags.contains("Boots") }.count
            if champ?.tags.contains("Assassin") == true, (champ?.attack ?? 0) + (champ?.magic ?? 0) > 0,
               enemy.scores.kills >= 3 || completed >= 2 {
                let label = enemy.scores.kills >= 3 ? "\(name) \(enemy.scores.kills) kills" : "\(name) \(completed) items"
                assassins.append((name, label))
            }
            let kills = Double(enemy.scores.kills)
            if enemy.scores.kills >= 4, kills >= avgKills * 1.5 || enemy.scores.kills - enemy.scores.deaths >= 4 {
                p.fedEnemies.append(name)
            }
        }

        p.adShare = weightSum > 0 ? min(1, max(0, adWeighted / weightSum)) : 0.5
        p.healing = min(1, healingParts.reduce(0) { $0 + $1.value })
        p.shields = min(1, shieldParts.reduce(0) { $0 + $1.value })
        p.armorStack = min(2, armorParts.map(\.ratio).max() ?? 0)
        p.mrStack = min(2, mrParts.map(\.ratio).max() ?? 0)
        p.critCarry = !critCarries.isEmpty
        p.heavyCC = ccNames.count >= 3
        p.burstAssassins = assassins.map(\.name)

        var reasons: [CounterCategory: [String]] = [:]
        let healers = healingParts.sorted { $0.value > $1.value }
        let strongHealers = healers.filter { $0.value >= 0.2 }
        reasons[.antiHeal] = (strongHealers.isEmpty ? Array(healers.prefix(1)) : strongHealers).map { "\($0.name) healing" }
        let armored = armorParts.filter { $0.ratio >= 1.1 }.sorted { $0.ratio > $1.ratio }
        reasons[.armorPen] = armored.map { "\($0.name) \($0.value) armor" }
        let mrStacked = mrParts.filter { $0.ratio >= 1.1 }.sorted { $0.ratio > $1.ratio }
        reasons[.magicPen] = mrStacked.map { "\($0.name) \($0.value) MR" }
        let adPct = Int((p.adShare * 100).rounded())
        reasons[.armor] = ["\(adPct)% AD damage"] + critCarries.map { "\($0) crit" }
        reasons[.magicResist] = ["\(100 - adPct)% AP damage"]
        reasons[.antiCrit] = critCarries.map { "\($0) crit" }
        reasons[.stasis] = assassins.map(\.label)
        reasons[.lifeline] = assassins.map(\.label)
        reasons[.spellShield] = assassins.map(\.label)
        reasons[.tenacity] = ccNames.isEmpty ? [] : [ccNames.prefix(3).joined(separator: " + ") + " CC"]
        reasons[.antiShield] = shieldParts.sorted { $0.value > $1.value }.map { "\($0.name) shields" }
        p.reasons = reasons.filter { !$0.value.isEmpty }
        return p
    }

    /// (ad share blended from champion kit and bought items, weight by how fed and itemized the enemy is).
    private static func damageBlend(champ: DDChampion?, items: [DDItem], kills: Int,
                                    classifier: ItemClassifier) -> (blend: Double, weight: Double) {
        let atk = Double(champ?.attack ?? 5), mag = Double(champ?.magic ?? 5)
        let champShare = atk + mag > 0 ? atk / (atk + mag) : 0.5
        var adGold = 0.0, apGold = 0.0, itemGold = 0.0
        for item in items {
            let d = classifier.damageProfile(item.id)
            adGold += d.ad * Double(item.goldTotal)
            apGold += d.ap * Double(item.goldTotal)
            itemGold += Double(item.goldTotal)
        }
        let itemShare = adGold + apGold > 0 ? adGold / (adGold + apGold) : champShare
        return (0.6 * champShare + 0.4 * itemShare, 1 + Double(kills) * 0.15 + itemGold / 3000)
    }

    private static func healingValue(id: String, items: [DDItem], keystone: Int?) -> Double {
        var heal = sustainChampions.contains(id) ? 0.25 : 0
        for item in items where item.goldTotal >= 1000 && isSustainItem(item) { heal += 0.1 }
        if let keystone, sustainKeystones.contains(keystone) { heal += 0.1 }
        return heal
    }

    private static func shieldValue(id: String, items: [DDItem]) -> Double {
        var shield = shieldChampions.contains(id) ? 0.3 : 0
        for item in items where shieldItems.contains(item.name) { shield += 0.15 }
        return shield
    }

    static func isSustainItem(_ item: DDItem) -> Bool {
        if (item.stats["PercentLifeStealMod"] ?? 0) > 0 { return true }
        if item.tags.contains("LifeSteal") || item.tags.contains("SpellVamp") { return true }
        let text = ItemClassifier.plainText(item.description)
        return text.contains("Omnivamp") || text.contains("Life Steal")
    }
}
