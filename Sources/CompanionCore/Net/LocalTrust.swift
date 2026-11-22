import Foundation

/// accepts the live client's self-signed certificate, but only for host 127.0.0.1.
public final class LocalTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    public static func shouldTrust(host: String) -> Bool { host == "127.0.0.1" }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.shouldTrust(host: space.host),
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    public static func localSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: LocalTrustDelegate(), delegateQueue: nil)
    }
}
