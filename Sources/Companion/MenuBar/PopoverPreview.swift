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
/// - champselect: only the champ select banner above a stand-in client, with sample op.gg advice; no popover.
/// - patterns: the client state with ten seeded games, so the "your last 10 games" card shows (expanded).
/// - ingame: the demo game fast-forwarded to a moment with a suggestion, a death and a spike alert, then frozen.
/// - scout: the ingame state with a sample scout card (fake players; rows open to sample champion pools).
@MainActor
final class PopoverPreview {
    enum Mode: String { case asleep, client, ingame, champselect, patterns, scout }

    private var window: NSWindow?
    private var banner: ChampSelectBannerController?
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
        if mode == .patterns {
            for r in Self.patternRecords() { await store.append(r) }
            UserDefaults.standard.set(true, forKey: "patternsCardExpanded")
        }

        let coordinator: Coordinator
        switch mode {
        case .asleep:
            coordinator = Coordinator.demo(store: store)
            coordinator.start()
        case .client, .champselect, .patterns:
            // a huge step keeps the timeline in its lobby slot forever; polls stay at the normal 2 s.
            coordinator = Coordinator.demo(store: store, stepDuration: .seconds(1_000_000))
            coordinator.start()
            // set (not just seeded) so bootstrap keeps it and tilt is evaluated with the lowered threshold.
            coordinator.updateSettings(Self.previewSettings(lowTilt: true))
            coordinator.leagueProcessChanged(clientRunning: true, gameRunning: false)
        case .ingame, .scout:
            let clock = GatedClock()
            coordinator = Coordinator.demo(store: store, clock: clock)
            coordinator.start()
            coordinator.leagueProcessChanged(clientRunning: true, gameRunning: true)
            freezeTask = Task { await Self.freeze(coordinator, clock: clock) }
            await freezeTask?.value
        }

        let model = AppModel(previewCoordinator: coordinator, directory: dir)
        if mode == .champselect {
            model.champSelectPreview = true
            coordinator.advisor.showPreview(advice: Self.sampleAdvice, champion: "Ahri", role: .mid,
                                            matchup: Self.sampleMatchup, championID: "Ahri",
                                            warnings: ["No frontline"])
            model.personalRecordPreview = Self.sampleRecord
        }
        if mode == .scout { coordinator.scout.showPreview(Self.sampleScout, pools: Self.samplePools) }
        self.model = model
        if mode != .champselect { present(model) }
        if mode == .champselect {
            let banner = ChampSelectBannerController(model: model, previewClient: Self.previewClient())
            banner.start()
            self.banner = banner
        }
        AppLog.app.notice("Popover preview shown (\(mode.rawValue, privacy: .public))")
        try? await Task.sleep(for: .seconds(3))
        let last = coordinator.lastSession.map { "\($0.wins)W \($0.losses)L" } ?? "none"
        AppLog.app.notice("Popover preview state: phase \(String(describing: coordinator.phase), privacy: .public), tilt \(coordinator.tilt?.message ?? "none", privacy: .public), last session \(last, privacy: .public), streak \(coordinator.goalStreak)")
    }

    /// a stand-in client window, 16:9, centered on the primary screen (`--banner-client <width>`, default 1280).
    private static func previewClient() -> CGRect {
        let args = ProcessInfo.processInfo.arguments
        let width = args.firstIndex(of: "--banner-client").flatMap { i in
            args.indices.contains(i + 1) ? Double(args[i + 1]) : nil
        } ?? 1280
        let frame = NSScreen.screens.first?.frame ?? .zero
        let height = width * 9 / 16
        return CGRect(x: (frame.midX - width / 2).rounded(), y: (frame.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    func stop() {
        banner?.stop()
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

    /// ten games whose deaths mostly come from an enemy jungler (a smite carrier) in the first 14 minutes.
    private static func patternRecords() -> [GameRecord] {
        let context = GameContext(participants: [
            .init(champion: "Jinx", isMe: true, isAlly: true),
            .init(champion: "Lee Sin", spells: ["SummonerFlash", "SummonerSmite"]),
            .init(champion: "Zed", spells: ["SummonerFlash", "SummonerDot"]),
        ])
        let now = Date()
        return (0..<10).map { i in
            let times: [Double] = i % 3 == 0 ? [330, 540, 900] : i % 3 == 1 ? [420] : [480, 1_500]
            let deaths = times.enumerated().map { n, time in
                DeathEvent(id: 1_000 + 10 * i + n, time: time, killer: (i + n) % 4 == 3 ? "Zed" : "Lee Sin")
            }
            let state: GoalState = i % 5 == 4 ? .failed : i % 5 == 2 ? .close : .achieved
            let progress = GoalProgress(goal: Goal(preset: .totalDeaths, target: 4), current: Double(deaths.count),
                                        state: state, label: "\(deaths.count) / 4 deaths")
            return GameRecord(id: "pattern-\(i)", date: now.addingTimeInterval(-Double(i + 3) * 86_400), champion: "Jinx",
                              role: .adc, win: i % 2 == 0, goalResult: progress, deaths: deaths, durationSec: 1_800,
                              isVoid: false, context: context)
        }
    }

    static let sampleScout: ScoutBoard = {
        func p(_ n: Int, _ champ: Int, _ rank: ScoutRank, me: Bool = false, _ flags: [ScoutFlag] = []) -> ScoutPlayer {
            ScoutPlayer(id: "preview-\(n)", championKey: champ, gameName: "Player\(n)", tagLine: "EUW", isMe: me, rank: rank,
                        flags: flags)
        }
        func r(_ tier: String, _ div: String?, _ lp: Int, _ w: Int, _ l: Int) -> ScoutRank {
            ScoutRank(tier: tier, division: div, lp: lp, wins: w, losses: l)
        }
        return ScoutBoard(teams: [
            ScoutTeam(title: "Your team", players: [
                p(1, 86, r("GOLD", "II", 45, 61, 52)), p(2, 64, r("PLATINUM", "IV", 12, 88, 79), [.streak(won: false, count: 4)]),
                p(3, 103, r("EMERALD", "III", 71, 120, 101)), p(4, 222, r("GOLD", "I", 88, 74, 66), me: true),
                p(5, 412, r("SILVER", "I", 30, 40, 41)),
            ]),
            ScoutTeam(title: "Enemy team", players: [
                p(6, 14, r("PLATINUM", "II", 54, 93, 80), [.oneTrick(share: 75)]), p(7, 234, r("DIAMOND", "IV", 9, 28, 9), [.likelySmurf(winRate: 76, games: 37), .streak(won: true, count: 6)]),
                p(8, 238, r("MASTER", nil, 212, 210, 175)), p(9, 51, .unranked, [.duo(partnerChampionKey: 89)]), p(10, 89, r("GOLD", "III", 0, 33, 35), [.newOnChampion, .duo(partnerChampionKey: 51)]),
            ]),
        ], region: "EUW")
    }()

    private static let samplePools: [String: ScoutPool] = [
        "preview-8": .loaded([PoolChampion(name: "Zed", games: 63, wins: 38), PoolChampion(name: "Yone", games: 41, wins: 21),
                              PoolChampion(name: "Ahri", games: 20, wins: 9)]),
    ]

    static let sampleRecord = PersonalRecord(champion: .init(wins: 9, games: 14), matchup: .init(wins: 1, games: 5))

    static let sampleMatchup = MatchupTip(
        verdict: .unfavored, opponent: "Zed",
        tip: "Do not use Charm [E] until Zed closes in using Living Shadow (W). If Zed has Death Mark (R) off cooldown, try to use Charm [E] after he reappears.",
        runes: RunePage(
            primaryStyleID: 8200, subStyleID: 8100, primaryStyleName: "Sorcery", subStyleName: "Domination",
            primaryIDs: [8992, 8226, 8210, 8237],
            primaryNames: ["Deathfire Touch", "Manaflow Band", "Transcendence", "Scorch"],
            secondaryIDs: [8106, 8139], secondaryNames: ["Ultimate Hunter", "Taste of Blood"],
            shardIDs: [5005, 5008, 5001], shardNames: ["Attack speed", "Adaptive force", "Health scaling"],
            play: 1993, win: 1001, pickRate: 0.47),
        coreItems: ["Malignance", "Shadowflame", "Zhonya's Hourglass"], coreItemIDs: [3118, 4645, 3157])

    static let sampleAdvice = ChampionAdvice(
        runes: RunePage(
            primaryStyleID: 8100, subStyleID: 8200, primaryStyleName: "Domination", subStyleName: "Sorcery",
            primaryIDs: [8112, 8139, 8140, 8106],
            primaryNames: ["Electrocute", "Taste of Blood", "Grisly Mementos", "Ultimate Hunter"],
            secondaryIDs: [8210, 8226], secondaryNames: ["Transcendence", "Manaflow Band"],
            shardIDs: [5005, 5008, 5001], shardNames: ["Attack speed", "Adaptive force", "Health scaling"],
            play: 52224, win: 26320, pickRate: 0.48),
        spellNames: ["Flash", "Ignite"], skillMax: ["Q", "W", "E"],
        counters: [CounterPick(championKey: 950, name: "Naafiri", winRate: 0.54, play: 362),
                   CounterPick(championKey: 1, name: "Annie", winRate: 0.53, play: 1851),
                   CounterPick(championKey: 105, name: "Fizz", winRate: 0.53, play: 1833)])

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
