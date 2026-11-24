import Foundation

/// where data dragon keeps the rune and summoner spell art: rune ids map to image paths, spells to file names.
public struct IconCatalog: Sendable {
    public let version: String
    private let runePaths: [Int: String]
    private let spellFiles: [String: String]

    private static let base = "https://ddragon.leagueoflegends.com/cdn"

    private static let shardFiles: [Int: String] = [
        5001: "HealthScaling", 5002: "Armor", 5003: "MagicRes", 5005: "AttackSpeed", 5007: "CDRScaling",
        5008: "AdaptiveForce", 5010: "MovementSpeed", 5011: "HealthPlus", 5013: "Tenacity",
    ]

    private struct Tree: Decodable {
        var id: Int
        var icon: String
        var slots: [Slot]
        struct Slot: Decodable { var runes: [Rune] }
        struct Rune: Decodable { var id: Int; var icon: String }
    }

    private struct SpellFile: Decodable {
        var data: [String: Spell]
        struct Spell: Decodable { var name: String; var image: Image }
        struct Image: Decodable { var full: String }
    }

    public static func decode(runes: Data, spells: Data, version: String) throws -> IconCatalog {
        var paths: [Int: String] = [:]
        for tree in try JSONDecoder().decode([Tree].self, from: runes) {
            paths[tree.id] = tree.icon
            for rune in tree.slots.flatMap(\.runes) { paths[rune.id] = rune.icon }
        }
        var files: [String: String] = [:]
        // event variants ("_Jade") share a name with the standard spell: keep the plain file.
        for spell in try JSONDecoder().decode(SpellFile.self, from: spells).data.values where !spell.image.full.contains("_") {
            files[spell.name.lowercased()] = spell.image.full
        }
        return IconCatalog(version: version, runePaths: paths, spellFiles: files)
    }

    public func runeURL(id: Int) -> URL? {
        runePaths[id].flatMap { URL(string: "\(Self.base)/img/\($0)") }
    }

    public func shardURL(id: Int) -> URL? {
        Self.shardFiles[id].flatMap { URL(string: "\(Self.base)/img/perk-images/StatMods/StatMods\($0)Icon.png") }
    }

    public func spellURL(name: String) -> URL? {
        spellFiles[name.lowercased()].flatMap { URL(string: "\(Self.base)/\(version)/img/spell/\($0)") }
    }
}
