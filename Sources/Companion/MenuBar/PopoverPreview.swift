import AppKit
import SwiftUI
import Synchronization
import CompanionCore

/// debug (--popover-preview <asleep|client|ingame>): the real popover view in a borderless floating window
/// near the top-right of the primary screen, until quit, driven by its own demo coordinator and throwaway store
/// (the app's own coordinator and store are untouched).
///
/// - asleep: seeded history (last session, goal streak), league closed.
/// - client: seeded history + demo lcu matches, tilt threshold lowered to 2 so the tilt card shows; lobby held.
/// - ingame: the demo game fast-forwarded to a moment with a suggestion, a death and a spike alert, then frozen.
@MainActor
final class PopoverPreview {
    enum Mode: String { case asleep, client, ingame }

    private var window: NSWindow?
    private(set) var model: AppModel?
    private var freezeTask: Task<Void, Never>?

    static func mode(from args: [String]) -> Mode? {
        guard let i = args.firstIndex(of: "--popover-preview") else { return nil }
        let next = args.indices.contains(i + 1) ? args[i + 1] : ""
        return Mode(rawValue: next.lowercased()) ?? .ingame
    }

    func show(_ mode: Mode) async {
        let tmp = FileManager.default.temporaryDirectory
        let prefix = "\(AppInfo.name)-popover-preview-"
        for old in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where old.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(old))
        }
        let dir = tmp.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        let store = Store(directory: dir)
        await Self.seed(store)

        let coordinator: Coordinator
        switch mode {
        case .asleep:
            coordinator = Coordinator.demo(store: store)
            coordinator.start()
        case .client:
            // a huge step keeps the timeline in its lobby slot forever; polls stay at the normal 2 s.
            coordinator = Coordinator.demo(store: store, stepDuration: .seconds(1_000_000))
            coordinator.start()
            // set (not just seeded) so bootstrap keeps it and tilt is evaluated with the lowered threshold.
            coordinator.updateSettings(Self.previewSettings(lowTilt: true))
            coordinator.leagueProcessChanged(clientRunning: true, gameRunning: false)
        case .ingame:
            let clock = GatedClock()
            coordinator = Coordinator.demo(store: store, clock: clock)
            coordinator.start()
            coordinator.leagueProcessChanged(clientRunning: true, gameRunning: true)
            freezeTask = Task { await Self.freeze(coordinator, clock: clock) }
            await freezeTask?.value
        }

        let model = AppModel(previewCoordinator: coordinator, directory: dir)
        self.model = model
        present(model)
        AppLog.app.notice("Popover preview shown (\(mode.rawValue, privacy: .public))")
        try? await Task.sleep(for: .seconds(3))
        let last = coordinator.lastSession.map { "\($0.wins)W \($0.losses)L" } ?? "none"
        AppLog.app.notice("Popover preview state: phase \(String(describing: coordinator.phase), privacy: .public), tilt \(coordinator.tilt?.message ?? "none", privacy: .public), last session \(last, privacy: .public), streak \(coordinator.goalStreak)")
    }

    func stop() {
        freezeTask?.cancel()
        model?.stop()
    }


    private var hostController: NSHostingController<PopoverView>?

    private func present(_ model: AppModel) {
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = host.view
        hostController = host

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.contentView = glass
        window = w
        resize()
        w.orderFrontRegardless()
        // the ingame section loads its item icon and the sections settle after the first layout pass.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.resize()
        }
    }

    private func resize() {
        guard let w = window, let host = hostController else { return }
        let fit = host.sizeThatFits(in: NSSize(width: 300, height: 2000))
        let size = NSSize(width: 300, height: max(fit.height, 120))
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        w.setFrame(NSRect(x: vf.maxX - 12 - size.width, y: vf.maxY - 8 - size.height,
                          width: size.width, height: size.height), display: true)
    }


    private static func seed(_ store: Store) async {
        let now = Date()
        let goal = Goal(preset: .deathsBefore14, target: 2)
        func record(_ i: Int, hoursAgo: Double, win: Bool, achieved: Bool, champion: String,
                    deaths count: Int) -> GameRecord {
            let deaths = (0..<count).map { n in
                DeathEvent(id: 100 * i + n, time: Double(300 + n * 420), killer: ["Zed", "Lee Sin", "Draven"][n % 3])
            }
            let progress = GoalProgress(goal: goal, current: achieved ? 1 : 3, state: achieved ? .achieved : .failed,
                                        label: achieved ? "1 / 2 deaths" : "3 / 2 deaths", deadline: 840)
            return GameRecord(id: "seed-\(i)", date: now.addingTimeInterval(-hoursAgo * 3600), champion: champion,
                              role: .adc, win: win, goalResult: progress, deaths: deaths, durationSec: 1_740,
                              isVoid: false)
        }
        let records = [
            record(1, hoursAgo: 27, win: true, achieved: false, champion: "Jinx", deaths: 3),
            record(2, hoursAgo: 2.4, win: false, achieved: true, champion: "Caitlyn", deaths: 1),
            record(3, hoursAgo: 1.8, win: true, achieved: true, champion: "Jinx", deaths: 2),
            record(4, hoursAgo: 1.2, win: true, achieved: true, champion: "Jinx", deaths: 1),
        ]
        for r in records { await store.append(r) }
        await store.save(previewSettings(lowTilt: false))
    }

    private static func previewSettings(lowTilt: Bool) -> AppSettings {
        var s = AppSettings()
        s.goal = Goal(preset: .deathsBefore14, target: 2)
        if lowTilt { s.tilt.lossStreak = 2 }
        return s
    }

    /// fast-forwards the demo game until it shows a suggestion, at least one death and a spike alert (or 20 s
    /// pass), then freezes every coordinator loop.
    private static func freeze(_ c: Coordinator, clock: GatedClock) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if c.phase == .inGame, c.suggestion != nil, c.goalProgress != nil, !c.spikeAlerts.isEmpty,
               (c.snapshot?.me?.scores.deaths ?? 0) >= 1 {
                break
            }
            if c.phase == .postGame { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        clock.close()
        let spike = c.spikeAlerts.first?.text ?? "none"
        AppLog.app.notice("Popover preview frozen: phase \(String(describing: c.phase), privacy: .public), next \(c.suggestion?.next.name ?? "none", privacy: .public), spike \(spike, privacy: .public), deaths \(c.snapshot?.me?.scores.deaths ?? 0)")
    }
}

/// clock for the ingame popover preview: poll sleeps take 25 ms while open (fast-forward) and never return once
/// closed (frozen state). spike-alert expiry sleeps (≥ 3.5 s) never return, so the shown alert stays.
final class GatedClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant

    private let open = Mutex(true)

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .milliseconds(1) }

    func close() { open.withLock { $0 = false } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let base = ContinuousClock()
        let requested = deadline - base.now
        let holdForever = requested >= .milliseconds(3_500)
        try await base.sleep(for: .milliseconds(25))
        while holdForever || !open.withLock({ $0 }) {
            try await base.sleep(for: .seconds(1))
        }
    }
}
