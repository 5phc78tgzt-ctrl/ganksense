import AppKit

/// starts league the way the riot client does: riotclientservices --launch-product=league_of_legends
/// --launch-patchline=live, with the path read from riotclientinstalls.json. falls back to opening
/// league of legends.app.
enum LeagueLauncher {
    enum Plan: Equatable {
        case riotClient(URL)
        case app(URL)
    }

    enum Outcome: Equatable {
        case launched
        case notInstalled
        case failed
    }

    static let installsFile = URL(fileURLWithPath: "/Users/Shared/Riot Games/RiotClientInstalls.json")
    static let leagueApp = URL(fileURLWithPath: "/Applications/League of Legends.app")
    static let arguments = ["--launch-product=league_of_legends", "--launch-patchline=live"]

    static func resolve(fileManager fm: FileManager = .default) -> Plan? {
        if let data = try? Data(contentsOf: installsFile),
           let exe = riotClientServices(fromInstallsJSON: data, isExecutable: { fm.isExecutableFile(atPath: $0.path) }) {
            return .riotClient(exe)
        }
        if fm.fileExists(atPath: leagueApp.path) { return .app(leagueApp) }
        return nil
    }

    /// preference: rc_live, rc_default, then any other string value (e.g. under associated_client).
    /// a value may name the executable or the riot client.app bundle.
    static func riotClientServices(fromInstallsJSON data: Data, isExecutable: (URL) -> Bool) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var candidates: [String] = []
        for key in ["rc_live", "rc_default"] { if let s = root[key] as? String { candidates.append(s) } }
        for (key, value) in root.sorted(by: { $0.key < $1.key }) where key != "rc_live" && key != "rc_default" {
            if let s = value as? String { candidates.append(s) }
            if let d = value as? [String: Any] {
                candidates += d.keys.sorted().compactMap { d[$0] as? String }
            }
        }
        for path in candidates {
            var url = URL(fileURLWithPath: path)
            if url.pathExtension == "app" { url = url.appendingPathComponent("Contents/MacOS/RiotClientServices") }
            if url.lastPathComponent == "RiotClientServices", isExecutable(url) { return url }
        }
        return nil
    }

    @MainActor
    static func launch() async -> Outcome {
        guard let plan = await Task.detached(operation: { resolve() }).value else { return .notInstalled }
        switch plan {
        case .riotClient(let exe):
            let p = Process()
            p.executableURL = exe
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                return .launched
            } catch {
                return await openApp() ? .launched : .failed
            }
        case .app:
            return await openApp() ? .launched : .failed
        }
    }

    @MainActor
    private static func openApp() async -> Bool {
        guard FileManager.default.fileExists(atPath: leagueApp.path) else { return false }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: leagueApp, configuration: .init())
            return true
        } catch {
            return false
        }
    }
}
