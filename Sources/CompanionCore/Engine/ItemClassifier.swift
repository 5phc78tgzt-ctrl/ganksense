import Foundation

public enum CounterCategory: String, CaseIterable, Sendable {
    case antiHeal, armorPen, magicPen, armor, magicResist, tenacity, stasis, spellShield, antiCrit, antiShield, lifeline
}

/// classifies items by data dragon data (stats keys, tags, description keywords), with a small curated
/// override table for anything text detection misses. unknown ids classify as empty / no damage.
public struct ItemClassifier: Sendable {
    public static let overrides: [String: Set<CounterCategory>] = [
        "Black Cleaver": [.armorPen],
        "Serpent's Fang": [.antiShield],
        "Randuin's Omen": [.antiCrit],
        "Mercurial Scimitar": [.tenacity],
        "Quicksilver Sash": [.tenacity],
        "Edge of Night": [.spellShield],
        "Banshee's Veil": [.spellShield],
        "Zhonya's Hourglass": [.stasis],
        "Guardian Angel": [.stasis],
        "Chempunk Chainsword": [.antiHeal],
        "Thornmail": [.antiHeal],
        "Morellonomicon": [.antiHeal],
        "Mortal Reminder": [.antiHeal, .armorPen],
    ]

    private let byID: [Int: Set<CounterCategory>]
    private let damage: [Int: (ad: Double, ap: Double)]

    public init(catalog: ItemCatalog) {
        var cats: [Int: Set<CounterCategory>] = [:]
        var dmg: [Int: (ad: Double, ap: Double)] = [:]
        for (id, item) in catalog.items {
            cats[id] = Self.classify(item)
            dmg[id] = Self.profile(item)
        }
        byID = cats
        damage = dmg
    }

    public func categories(_ id: Int) -> Set<CounterCategory> { byID[id] ?? [] }

    public func damageProfile(_ id: Int) -> (ad: Double, ap: Double) { damage[id] ?? (0, 0) }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    static func classify(_ item: DDItem) -> Set<CounterCategory> {
        let text = plainText(item.description)
        let lower = text.lowercased()
        let tags = Set(item.tags)
        var c: Set<CounterCategory> = []
        if text.contains("Wounds") { c.insert(.antiHeal) }
        if tags.contains("ArmorPenetration") || text.contains("Armor Penetration") || text.contains("Lethality") {
            c.insert(.armorPen)
        }
        if (tags.contains("MagicPenetration") || text.contains("Magic Penetration")) && !tags.contains("Boots") {
            c.insert(.magicPen)
        }
        if (item.stats["FlatArmorMod"] ?? 0) >= 30 { c.insert(.armor) }
        if (item.stats["FlatSpellBlockMod"] ?? 0) >= 30 { c.insert(.magicResist) }
        if tags.contains("Tenacity") || text.contains("Tenacity") || text.contains("Quicksilver")
            || lower.contains("cleanse") || lower.contains("remove all crowd control")
            || lower.contains("removes all crowd control") {
            c.insert(.tenacity)
        }
        if text.contains("Stasis") { c.insert(.stasis) }
        if lower.contains("spell shield") || lower.contains("spellshield") { c.insert(.spellShield) }
        if lower.contains("damage from critical strike") { c.insert(.antiCrit) }
        if lower.contains("reduces shields") || lower.contains("shield reaver") { c.insert(.antiShield) }
        if text.contains("Lifeline") { c.insert(.lifeline) }
        if let extra = overrides[item.name] { c.formUnion(extra) }
        return c
    }

    static func profile(_ item: DDItem) -> (ad: Double, ap: Double) {
        let s = item.stats
        let tags = Set(item.tags)
        var ad = (s["FlatPhysicalDamageMod"] ?? 0)
            + (s["FlatCritChanceMod"] ?? 0) * 100
            + (s["PercentAttackSpeedMod"] ?? 0) * 60
        var ap = s["FlatMagicDamageMod"] ?? 0
        // items whose damage stat is only in the text (e.g. sterak's bonus ad) still lean on their tags.
        if ad == 0, tags.contains("Damage") { ad = 20 }
        if ap == 0, tags.contains("SpellDamage") { ap = 20 }
        if tags.contains("Boots") {
            // boots: orientation only from their offensive tags, never from move speed.
            ad = tags.contains("AttackSpeed") ? 1 : 0
            ap = tags.contains("MagicPenetration") ? 1 : 0
        }
        let total = ad + ap
        guard total > 0 else { return (0, 0) }
        return (ad / total, ap / total)
    }
}
