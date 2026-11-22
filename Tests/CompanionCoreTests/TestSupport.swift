import Foundation
@testable import CompanionCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// data dragon over a temp cache dir holding the fixtures under the given versions, with a network that always fails.
func makeOfflineDataDragon(versions: [String]) throws -> (DataDragon, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(UUID().uuidString)")
    for v in versions {
        let vd = dir.appendingPathComponent(v)
        try FileManager.default.createDirectory(at: vd, withIntermediateDirectories: true)
        try loadFixtureData("item_sr").write(to: vd.appendingPathComponent("item.json"))
        try loadFixtureData("champion_all").write(to: vd.appendingPathComponent("champion.json"))
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return (DataDragon(cacheDir: dir, session: URLSession(configuration: cfg)),
            { try? FileManager.default.removeItem(at: dir) })
}
