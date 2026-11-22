import Foundation

public enum LiveClientError: Error, Sendable, Equatable {
    case notRunning, notReady, badPayload
}

public protocol LiveGameSource: Sendable {
    func fetch() async throws -> LiveGameSnapshot
}

public final class LiveClient: LiveGameSource {
    public static let endpoint = URL(string: "https://127.0.0.1:2999/liveclientdata/allgamedata")!
    public static let timeout: TimeInterval = 1.5

    private let session: URLSession
    private let url: URL

    public init(session: URLSession = LocalTrustDelegate.localSession(), url: URL = LiveClient.endpoint) {
        self.session = session
        self.url = url
    }

    public func fetch() async throws -> LiveGameSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost, .timedOut: throw LiveClientError.notRunning
            default: throw e
            }
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw LiveClientError.notReady }
            guard (200..<300).contains(http.statusCode) else { throw LiveClientError.badPayload }
        }
        guard let snapshot = try? JSONDecoder().decode(LiveGameSnapshot.self, from: data) else {
            throw LiveClientError.badPayload
        }
        guard !snapshot.allPlayers.isEmpty else { throw LiveClientError.notReady }
        return snapshot
    }
}
