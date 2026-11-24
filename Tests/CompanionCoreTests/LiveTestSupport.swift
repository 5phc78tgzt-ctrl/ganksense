// foundation only, never testing: see coordinatortestsupport.swift.
import Foundation
@testable import CompanionCore

func loadFixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw URLError(.fileDoesNotExist)
    }
    return try Data(contentsOf: url)
}

func loadSnapshot(_ name: String) throws -> LiveGameSnapshot {
    try JSONDecoder().decode(LiveGameSnapshot.self, from: loadFixtureData(name))
}

func decodeSnapshot(json: String) throws -> LiveGameSnapshot {
    try JSONDecoder().decode(LiveGameSnapshot.self, from: Data(json.utf8))
}

func goldPlayer(_ team: Team, _ position: String?, items: [PlayerItem], name: String) -> Player {
    Player(championName: name, team: team, items: items, summonerName: name, position: position)
}

func goldCatalog() -> ItemCatalog {
    func item(_ id: Int, _ total: Int, _ tags: [String] = []) -> DDItem { DDItem(id: id, name: "i\(id)", goldTotal: total, tags: tags) }
    return ItemCatalog(version: "t", items: [1: item(1, 3000), 2: item(2, 1000), 3: item(3, 50, ["Consumable"]),
                                              4: item(4, 0, ["Trinket"])])
}
