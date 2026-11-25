import Foundation

/// asks ganksense.app which version is current. the request carries nothing about the user, and the app never
/// replaces itself: a newer version only shows a notice with the install command.
public enum UpdateCheck {
    public static let manifestURL = URL(string: "https://ganksense.app/version.json")!
    /// running the installer again is the update: it swaps the app and keeps settings and history.
    public static let command = "curl -fsSL https://ganksense.app/install.sh | bash"

    private struct Manifest: Decodable { var version: String }

    /// the published version, or nil when the site can't be reached or the body isn't a version.
    public static func latestVersion(session: URLSession = URLSession(configuration: .ephemeral)) async -> String? {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        // the default user agent names the macos kernel version.
        request.setValue(AppInfo.name, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return version(in: data)
    }

    /// reads `{"version":"1.2.3"}`. anything but dotted numbers is rejected, since the text is shown in the ui.
    static func version(in data: Data) -> String? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              parts(manifest.version) != nil
        else { return nil }
        return manifest.version
    }

    /// numeric comparison part by part, missing parts counting as zero; false when either side isn't a version.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parts(candidate), var b = parts(current) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    private static func parts(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        let numbers = pieces.compactMap { piece in
            piece.allSatisfy { $0.isASCII && $0.isNumber } ? Int(piece) : nil
        }
        return numbers.count == pieces.count ? numbers : nil
    }
}
