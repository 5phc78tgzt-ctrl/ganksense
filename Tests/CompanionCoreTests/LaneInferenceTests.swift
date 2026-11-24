import Testing
@testable import CompanionCore

/// normal draft: the client gives no enemy positions. Teemo top into Orianna, Seraphine, Lillia, Mel, K'Sante
/// must find K'Sante, and Seraphine must not take mid from Orianna or Mel.
@Test func infersTheLaneOpponentWithoutEnemyPositions() {
    let roster = [
        DDChampion(id: "Orianna", key: 61, name: "Orianna", tags: ["Mage", "Support"]),
        DDChampion(id: "Seraphine", key: 147, name: "Seraphine", tags: ["Mage", "Support"]),
        DDChampion(id: "Lillia", key: 876, name: "Lillia", tags: ["Fighter", "Mage"]),
        DDChampion(id: "Mel", key: 800, name: "Mel", tags: ["Mage", "Support"]),
        DDChampion(id: "KSante", key: 897, name: "K'Sante", tags: ["Tank", "Fighter"]),
    ]
    let lanes = LaneInference.assign(championKeys: roster.map(\.key),
                                     catalog: ChampionCatalog(version: "test", champions: roster))
    #expect(lanes.first { $0.value == .top }?.key == 897)
    #expect(lanes[876] == .jungle)
    #expect(Set(lanes.values).count == 5)
    #expect(lanes[147] != .mid)
}
