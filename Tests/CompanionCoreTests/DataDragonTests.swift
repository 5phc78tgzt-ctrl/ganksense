import Testing
@testable import CompanionCore


@Test func cacheIsUsedWhenOffline() async throws {
    let (dd, cleanup) = try makeOfflineDataDragon(versions: ["16.9.1", "16.23.1"])
    defer { cleanup() }
    #expect(try await dd.latestVersion() == "16.23.1")
    #expect(try await dd.items(version: "16.23.1").item(3157)?.name == "Zhonya's Hourglass")
    #expect(try await dd.champions(version: "16.23.1").champion(key: 103)?.id == "Ahri")
    #expect(await dd.loadCached()?.0.version == "16.23.1")
    #expect(dd.itemIconURL(id: 3157, version: "16.23.1").absoluteString.hasSuffix("/cdn/16.23.1/img/item/3157.png"))
}
