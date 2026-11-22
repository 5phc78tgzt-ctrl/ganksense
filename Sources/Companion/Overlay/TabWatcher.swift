import AppKit
import Carbon.HIToolbox
import CompanionCore

/// hold-tab for the overlay. while enabled (see `tabgate`), samples whether tab is down at 20 hz with the public
/// `cgeventsource.keystate` api: no event tap, nothing synthesized and nothing recorded. macOS may still ask for
/// input monitoring for this call; without it the key reads as up. the timer exists only while enabled; otherwise nothing runs.
///
/// "league's game window is frontmost" comes from `nsworkspace.frontmostapplication` (bundle id
/// `com.riotgames.leagueoflegends.gameclient`, or the `leagueoflegends` executable), kept current by the
/// workspace's app-activation notification, so polling stops the moment another app (or the client) comes forward.
///
/// hidden debug flag `--simulate-tab`: treats the game as frontmost and replaces the key state with a fixed
/// pattern (tab held 1.5 s of every 5 s, and a cmd-tab between), for checking the overlay without league.
@MainActor
final class TabWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var held = false

    private var timer: Timer?
    private var filter = TabHoldFilter()
    private var activationObserver: NSObjectProtocol?
    private let simulate = CommandLine.arguments.contains("--simulate-tab")
    private let simulationStart = Date()

    static let interval: TimeInterval = 0.05

    private(set) var gameFrontmost = false
    /// called when `gamefrontmost` changes, so the owner can re-evaluate the gate.
    var onFrontmostChange: (() -> Void)?

    init() {
        gameFrontmost = simulate || Self.isGame(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isGame = Self.isGame(app)
            MainActor.assumeIsolated {
                guard let self, !self.simulate, isGame != self.gameFrontmost else { return }
                self.gameFrontmost = isGame
                self.onFrontmostChange?()
            }
        }
    }

    nonisolated static func isGame(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        return LeagueProcessWatcher.kind(bundleID: app.bundleIdentifier,
                                         executable: app.executableURL?.lastPathComponent) == .game
    }

    /// starts or stops sampling. stopping drops the held state at once (reported through `onchange`).
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            filter.reset()
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common)
            timer = t
            AppLog.app.notice("Tab watch on")
        } else {
            guard let timer else { return }
            timer.invalidate()
            self.timer = nil
            filter.reset()
            AppLog.app.notice("Tab watch off")
            report(false)
        }
    }

    private func tick() {
        let (tabDown, modifierDown) = simulate ? simulatedSample() : Self.sample()
        report(filter.sample(tabDown: tabDown, modifierDown: modifierDown))
    }

    private func report(_ value: Bool) {
        guard value != held else { return }
        held = value
        onChange?(value)
    }

    /// reads only whether tab and the command/option/control modifiers are down right now.
    private static func sample() -> (tab: Bool, modifier: Bool) {
        let tab = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Tab))
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifier = !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
        return (tab, modifier)
    }

    /// 5 s cycle: tab held 1.0–2.5 s; cmd-tab (ignored) 3.5–4.0 s.
    private func simulatedSample() -> (tab: Bool, modifier: Bool) {
        let t = Date().timeIntervalSince(simulationStart).truncatingRemainder(dividingBy: 5)
        if t >= 1.0 && t < 2.5 { return (true, false) }
        if t >= 3.5 && t < 4.0 { return (true, true) }
        return (false, false)
    }
}
