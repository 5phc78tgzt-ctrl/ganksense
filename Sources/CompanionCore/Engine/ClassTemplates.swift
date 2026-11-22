import Foundation

public enum ChampionArchetype: String, CaseIterable, Sendable {
    case marksman, mage, assassinAD, fighter, tank, enchanter

    public init(champion: DDChampion) {
        let tags = champion.tags
        let apLeaning = champion.magic > champion.attack
        switch tags.first {
        case "Marksman": self = .marksman
        case "Mage": self = .mage
        case "Assassin": self = apLeaning ? .mage : .assassinAD
        case "Fighter": self = apLeaning ? .mage : .fighter
        case "Tank": self = .tank
        case "Support":
            if tags.contains("Tank") || champion.defense >= 7 { self = .tank }
            else if apLeaning || tags.contains("Mage") { self = .enchanter }
            else { self = .tank }
        default:
            self = apLeaning ? .mage : .fighter
        }
    }
}

/// fallback base builds per archetype, used when op.gg is off, unreachable or drifts.
/// item **names** are resolved through the catalog; unresolvable names are dropped.
public enum ClassTemplates {
    struct Template {
        var starter: [String]
        var core: [String]
        var boots: String
        var situational: [String]
    }

    static let templates: [ChampionArchetype: Template] = [
        .marksman: Template(
            starter: ["Doran's Blade", "Health Potion"],
            core: ["Yun Tal Wildarrows", "Infinity Edge", "Phantom Dancer", "Lord Dominik's Regards", "Bloodthirster"],
            boots: "Berserker's Greaves",
            situational: ["Mortal Reminder", "Guardian Angel", "Mercurial Scimitar", "Kraken Slayer",
                          "Blade of The Ruined King", "Immortal Shieldbow"]),
        .mage: Template(
            starter: ["Doran's Ring", "Health Potion"],
            core: ["Luden's Echo", "Shadowflame", "Rabadon's Deathcap", "Void Staff", "Zhonya's Hourglass"],
            boots: "Sorcerer's Shoes",
            situational: ["Banshee's Veil", "Morellonomicon", "Cryptbloom", "Malignance", "Liandry's Torment"]),
        .assassinAD: Template(
            starter: ["Long Sword", "Health Potion"],
            core: ["Youmuu's Ghostblade", "Opportunity", "Edge of Night", "Serylda's Grudge", "Serpent's Fang"],
            boots: "Ionian Boots of Lucidity",
            situational: ["Guardian Angel", "Maw of Malmortius", "Chempunk Chainsword", "Axiom Arc", "Hubris"]),
        .fighter: Template(
            starter: ["Doran's Blade", "Health Potion"],
            core: ["Sundered Sky", "Black Cleaver", "Sterak's Gage", "Death's Dance", "Spirit Visage"],
            boots: "Plated Steelcaps",
            situational: ["Chempunk Chainsword", "Maw of Malmortius", "Thornmail", "Randuin's Omen",
                          "Guardian Angel", "Kaenic Rookern"]),
        .tank: Template(
            starter: ["Doran's Shield", "Health Potion"],
            core: ["Sunfire Aegis", "Thornmail", "Spirit Visage", "Randuin's Omen", "Kaenic Rookern"],
            boots: "Plated Steelcaps",
            situational: ["Force of Nature", "Frozen Heart", "Dead Man's Plate", "Jak'Sho, The Protean",
                          "Abyssal Mask", "Warmog's Armor"]),
        .enchanter: Template(
            starter: ["World Atlas", "Health Potion"],
            core: ["Moonstone Renewer", "Ardent Censer", "Redemption", "Mikael's Blessing", "Staff of Flowing Water"],
            boots: "Ionian Boots of Lucidity",
            situational: ["Locket of the Iron Solari", "Echoes of Helia", "Imperial Mandate", "Morellonomicon",
                          "Zhonya's Hourglass"]),
    ]

    public static func baseBuild(for champion: DDChampion, role: Role, catalog: ItemCatalog, patch: String) -> BaseBuild {
        var archetype = ChampionArchetype(champion: champion)
        // a marksman or mage sent to support keeps its class; a fighter/tank in support plays like a tank.
        if role == .support, archetype == .fighter { archetype = .tank }
        return baseBuild(archetype: archetype, champion: champion.id, role: role, catalog: catalog, patch: patch)
    }

    public static func baseBuild(archetype: ChampionArchetype, champion: String, role: Role,
                                 catalog: ItemCatalog, patch: String) -> BaseBuild {
        let t = templates[archetype]!
        func ids(_ names: [String]) -> [Int] { names.compactMap { catalog.item(named: $0)?.id } }
        return BaseBuild(champion: champion, role: role, starter: ids(t.starter), core: ids(t.core),
                         boots: catalog.item(named: t.boots)?.id, situational: ids(t.situational),
                         source: .template, patch: patch)
    }
}
