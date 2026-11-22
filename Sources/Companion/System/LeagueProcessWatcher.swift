import AppKit

@MainActor
protocol LeagueProcessWatching: AnyObject {
    func start(onChange: @escaping @MainActor (_ clientRunning: Bool, _ gameRunning: Bool) -> Void)
    func stop()
}

/// nsworkspace launch/terminate notifications plus an initial scan. no timers: idle cost is zero while league
/// is closed. every notification triggers a rescan of running applications (cheap, and it avoids carrying
/// non-sendable payloads across actors); the callback fires only when the (client, game) pair changes.
@MainActor
final class LeagueProcessWatcher: LeagueProcessWatching {
    nonisolated static let clientBundleID = "com.riotgames.LeagueofLegends.LeagueClient"
    nonisolated static let gameBundleID = "com.riotgames.LeagueofLegends.GameClient"

    private var observers: [NSObjectProtocol] = []
    private var onChange: (@MainActor (Bool, Bool) -> Void)?
    private var last: (client: Bool, game: Bool)?

    func start(onChange: @escaping @MainActor (Bool, Bool) -> Void) {
        guard observers.isEmpty else { return }
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            })
        }
        rescan()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
        onChange = nil
    }

    private func rescan() {
        var client = false, game = false
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            switch Self.kind(bundleID: app.bundleIdentifier, executable: app.executableURL?.lastPathComponent) {
            case .client?: client = true
            case .game?: game = true
            case nil: break
            }
        }
        if let last, last.client == client, last.game == game { return }
        last = (client, game)
        onChange?(client, game)
    }

    enum Kind { case client, game }

    /// bundle id first (league client, also matches leagueclientux helpers), executable name as a fallback.
    nonisolated static func kind(bundleID: String?, executable: String?) -> Kind? {
        if let id = bundleID {
            if id == gameBundleID { return .game }
            if id.hasPrefix(clientBundleID) { return .client }
        }
        switch executable {
        case "LeagueofLegends"?: return .game
        case "LeagueClient"?: return .client
        default: return nil
        }
    }
}

@MainActor
final class DemoProcessWatcher: LeagueProcessWatching {
    private var onChange: (@MainActor (Bool, Bool) -> Void)?

    func start(onChange: @escaping @MainActor (Bool, Bool) -> Void) {
        self.onChange = onChange
        onChange(true, true)
    }

    func exitGame() { onChange?(true, false) }

    func stop() { onChange = nil }
}
