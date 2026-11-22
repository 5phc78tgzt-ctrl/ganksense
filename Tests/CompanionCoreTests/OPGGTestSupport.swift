// foundation only, never testing: see coordinatortestsupport.swift.
import Foundation
import Synchronization
@testable import CompanionCore

final class OPGGStubProtocol: URLProtocol {
    enum Mode: Sendable {
        case respond(status: Int, body: String)
        case hang
    }

    static let mode = Mutex<Mode>(.hang)
    static let count = Mutex<Int>(0)

    static func reset(_ m: Mode) {
        mode.withLock { $0 = m }
        count.withLock { $0 = 0 }
    }

    static func requestCount() -> Int { count.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.count.withLock { $0 += 1 }
        switch Self.mode.withLock({ $0 }) {
        case .hang:
            return
        case let .respond(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

enum OPGGTestSupport {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OPGGStubProtocol.self]
        return URLSession(configuration: config)
    }

    static func freshCacheDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opgg-tests-\(UUID().uuidString)", isDirectory: true)
    }

    static func extractText(_ body: String) -> String? {
        OPGGClient.extractText(Data(body.utf8))
    }
}
