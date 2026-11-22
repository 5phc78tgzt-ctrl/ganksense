import Foundation
import Observation

public enum AppPhase: Equatable, Sendable {
    /// league closed: no tasks running, only process notifications.
    case asleep
    /// client open (or the game process is up but the live client api has not answered yet).
    case client(GameflowPhase)
    /// game process / live client up. `snapshot` stays nil during the loading screen.
    case inGame
    /// the game was finalized; lasts until the client reports a pre-game phase (lobby, champ select, …).
    case postGame
}

/// the app's state machine. event-driven: league process changed (from ns workspace) starts and stops the polling
/// loops; league closed → no tasks at all.
///
/// loops (cancelled on every phase change that no longer needs them):
/// - client loop, while the client process runs: gameflow phase every client poll interval (2 s); champ select
///   info while in champ select.
/// - live loop, while the game process runs or the client says the game is in progress: `live.fetch()` every
///   live poll interval (1 s). engines recompute only when the snapshot changed.
///
/// end of game: not running after a game end event, reconnect grace polls consecutive not running polls,
/// or the game process exiting while the client is gone / past the game. a crash (process exit, client in
/// reconnect) suspends the game instead; the same roster coming back resumes it, so deaths (keyed by eventid)
/// are never double-counted and one game makes exactly one record.
@MainActor @Observable
public final class Coordinator {

    public private(set) var phase: AppPhase = .asleep
    /// latest *ready* snapshot of the current game (never a loading-screen payload); nil outside a game.
    public private(set) var snapshot: LiveGameSnapshot?
    public private(set) var suggestion: BuildSuggestion?
    public private(set) var threat: ThreatProfile?
    /// live goal badge; after the game, the final (latched) result until the next game starts.
    public private(set) var goalProgress: GoalProgress?
    /// at most one alert; each shows for spike alert duration (4 s), further alerts queue.
    public private(set) var spikeAlerts: [SpikeAlert] = []
    /// informational enemy-jungler line (coarse, changes rarely); nil when unknown, stale or disabled.
    public private(set) var jungler: JunglerStatus?
    public private(set) var tilt: TiltStatus?
    public private(set) var settings = Settings()
    /// consecutive most recent non-void games whose goal was achieved (games without a goal are skipped).
    public private(set) var goalStreak = 0
    /// wins/losses of the most recent play session from local records (games < 45 min apart); nil if none.
    public private(set) var lastSession: (wins: Int, losses: Int)?
    /// the review to show right now: set when the end-of-game flow starts (and the game process is gone) for a game
    /// with deaths, cleared by review lifecycle when that flow is left or league closes, or by dismiss review().
    /// the record itself stays in `records` either way (see latest reviewable record).
    public private(set) var pendingReview: GameRecord?
    public private(set) var itemCatalog: ItemCatalog?
    /// primary likely-cause counts over the deaths of the 20 most recent games (death analyzer; "unclear" included).
    public private(set) var deathCauseStats: [DeathCause: Int] = [:]

    /// all stored games, oldest first.
    public private(set) var records: [GameRecord] = []
    public private(set) var championCatalog: ChampionCatalog?
    /// last champ select pick/role read from the client.
    public private(set) var champSelectInfo: ChampSelectInfo?
    /// base build in use for the current game (op.gg or template).
    public private(set) var baseBuild: BaseBuild?
    /// called once each time the tilt guard starts nudging (reason goes from none to some, or changes kind).
    @ObservationIgnored public var onTiltNudge: ((String) -> Void)?

    public nonisolated static let livePollInterval: Duration = .seconds(1)
    public nonisolated static let clientPollInterval: Duration = .seconds(2)
    public nonisolated static let spikeAlertDuration: Duration = .seconds(4)
    /// consecutive not running live polls (≈ seconds) tolerated before a game without game end is finalized.
    public nonisolated static let reconnectGracePolls = 10
    /// games shorter than this are remakes: is void, no goal result, excluded from streaks.
    public nonisolated static let voidThreshold: Double = 300

    private static let preGamePhases: Set<GameflowPhase> = [.none, .lobby, .matchmaking, .readyCheck, .champSelect]
    private static let gameAlivePhases: Set<GameflowPhase> = [.inProgress, .reconnect, .gameStart]
    private static let postGamePhases: Set<GameflowPhase> = [.waitingForStats, .preEndOfGame, .endOfGame]
    private static let recentMatchCount = 20
    private static let spikeHistoryLimit = 50

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let dataDragon: DataDragon?
    @ObservationIgnored private let makeClient: () -> ClientSource?
    @ObservationIgnored private let live: LiveGameSource
    @ObservationIgnored private let buildSource: BaseBuildSource?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// wall clock for records and the tilt guard (tests may replace it).
    @ObservationIgnored var now: () -> Date = { Date() }
    /// applied after settings load when no goal is set (demo only).
    @ObservationIgnored var defaultGoal: Goal?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var clientRunning = false
    @ObservationIgnored private var gameRunning = false
    @ObservationIgnored private var client: ClientSource?
    @ObservationIgnored private var lcuPhase: GameflowPhase?
    @ObservationIgnored private var clientSessionStart: Date?
    @ObservationIgnored private var matches: [MatchSummary]?
    @ObservationIgnored private var tiltFetchedForClient = false
    /// the client showed a post-game phase and has not yet returned to a pre-game one: history is re-fetched then.
    @ObservationIgnored private var awaitingPostGameRefresh = false
    @ObservationIgnored private var lastNudgeKind: String?
    @ObservationIgnored private var liveResponding = false
    @ObservationIgnored private var notRunningStreak = 0
    /// set when a game is finalized: keeps the live loop off until a pre-game phase or a new game process.
    @ObservationIgnored private var finishedLatch = false
    /// the finished game whose review belongs to the current end-of-game flow (see sync review).
    @ObservationIgnored private var reviewCandidateID: String?
    @ObservationIgnored private var lastFinishedRoster: String?
    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engine: CounterBuildEngine?
    @ObservationIgnored private var prefetchedBase: BaseBuild?
    @ObservationIgnored private var spikeQueue: [SpikeAlert] = []
    @ObservationIgnored private var settingsTouched = false

    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var spikeTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var tiltTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// every alert ever shown, newest last (tests; capped).
    @ObservationIgnored private(set) var spikeHistory: [SpikeAlert] = []

    public init(store: Store, dataDragon: DataDragon?, makeClient: @escaping () -> ClientSource?,
                live: LiveGameSource, buildSource: BaseBuildSource?,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.store = store
        self.dataDragon = dataDragon
        self.makeClient = makeClient
        self.live = live
        self.buildSource = buildSource
        self.sleep = Self.sleeper(clock)
    }

    private nonisolated static func sleeper<C: Clock>(_ clock: C) -> @Sendable (Duration) async throws -> Void
        where C.Duration == Duration {
        { try await clock.sleep(for: $0) }
    }

    /// demo: bundled catalogs, demo live source + demo client source sharing one demo timeline, template builds,
    /// no network. pair with a watcher that reports client and game running. use a throwaway `store` directory:
    /// the demo game is recorded like a real one.
    public static func demo(store: Store, stepDuration: Duration = .seconds(3),
                            clock: any Clock<Duration> = ContinuousClock()) -> Coordinator {
        let timeline = DemoTimeline.bundled(stepDuration: stepDuration)
        let client = DemoClientSource(timeline: timeline)
        let coordinator = Coordinator(store: store, dataDragon: nil, makeClient: { client },
                                      live: DemoLiveSource(timeline: timeline), buildSource: nil, clock: clock)
        coordinator.defaultGoal = Goal(preset: .deathsBefore14, target: 2)
        return coordinator
    }

    /// loads settings, records and catalogs (cached data dragon → bundled fallback), then checks data dragon for
    /// a newer patch. one-shot; starts no loop.
    public func start() {
        guard !started else { return }
        started = true
        bootTask = Task { [weak self] in await self?.bootstrap() }
    }

    /// cancels every task (app termination, tests).
    public func stop() {
        for task in [clientTask, liveTask, spikeTask, prefetchTask, catalogTask, tiltTask, bootTask] { task?.cancel() }
        clientTask = nil
        liveTask = nil
        spikeTask = nil
        prefetchTask = nil
        catalogTask = nil
        tiltTask = nil
        bootTask = nil
        session?.baseFetch?.cancel()
    }

    public func leagueProcessChanged(clientRunning: Bool, gameRunning: Bool) {
        let clientOpened = clientRunning && !self.clientRunning
        let gameStarted = gameRunning && !self.gameRunning
        let gameExited = !gameRunning && self.gameRunning
        self.clientRunning = clientRunning
        self.gameRunning = gameRunning

        if clientOpened { beginClientSession() }
        if !clientRunning {
            client = nil
            lcuPhase = nil
        }
        if gameStarted { finishedLatch = false }
        if gameExited { handleGameProcessExit() }
        reconcile()
    }

    public func setGoal(_ goal: Goal?) {
        var s = settings
        s.goal = goal
        updateSettings(s)
    }

    public func updateSettings(_ s: Settings) {
        let old = settings
        settings = s
        settingsTouched = true
        persist { store in await store.save(s) }
        if old.tilt != s.tilt { evaluateTilt() }
        if old.showJunglerLine != s.showJunglerLine, !s.showJunglerLine { jungler = nil }
        if old.goal != s.goal || old.goalTargets != s.goalTargets, let game = session {
            game.goalLatched = nil
            updateGoal(game)
        }
    }

    public func dismissReview() {
        closeReview()
    }

    /// the most recent stored game with at least one death: what "review last game" reopens. closing the review
    /// window never removes it.
    public var latestReviewableRecord: GameRecord? {
        ReviewLifecycle.latestReviewable(in: records)
    }

    /// deletes the game history (records and everything derived from it); settings stay. the review window
    /// closes, the streak, session and death-cause stats reset. queued store writes finish first.
    public func purgeHistory() {
        records = []
        reviewCandidateID = nil
        pendingReview = nil
        persist { store in await store.purgeHistory() }
        recomputeHistoryStats()
    }

    /// the data dragon snapshot shipped in the bundle (offline fallback and demo).
    public nonisolated static func bundledCatalogs() -> (ItemCatalog, ChampionCatalog)? {
        struct Version: Decodable { var version: String? }
        guard let items = try? DemoTimeline.fixtureData("item_sr"),
              let champs = try? DemoTimeline.fixtureData("champion_all") else { return nil }
        let version = (try? JSONDecoder().decode(Version.self, from: items))?.version ?? "16.23.1"
        guard let itemCatalog = try? ItemCatalog.decode(items, version: version),
              let championCatalog = try? ChampionCatalog.decode(champs, version: version) else { return nil }
        return (itemCatalog, championCatalog)
    }

    /// installs catalogs; the engine (item classifier) is built off the main actor, once per catalog.
    public func installCatalogs(items: ItemCatalog, champions: ChampionCatalog) async {
        let built = await Task.detached { CounterBuildEngine(catalog: items, champions: champions) }.value
        engine = built
        itemCatalog = items
        championCatalog = champions
        if let game = session, snapshot != nil { recompute(game) }
    }

    var hasActiveLoops: Bool { clientTask != nil || liveTask != nil }

    /// waits for queued store writes.
    func flushPersistence() async {
        await persistTask?.value
    }

    static func rosterKey(_ s: LiveGameSnapshot) -> String {
        s.allPlayers.map { "\($0.team)-\($0.championName)" }.sorted().joined(separator: ",")
    }

    static func defaultRole(for archetype: ChampionArchetype) -> Role {
        switch archetype {
        case .marksman: .adc
        case .mage, .assassinAD: .mid
        case .fighter, .tank: .top
        case .enchanter: .support
        }
    }
}


private extension Coordinator {
    func bootstrap() async {
        let loaded = await store.loadSettings()
        if !settingsTouched {
            settings = loaded
            if settings.goal == nil, let goal = defaultGoal { settings.goal = goal }
        }
        records = await store.records()
        if engine == nil, let (items, champions) = await dataDragon?.loadCached() ?? Self.bundledCatalogs() {
            await installCatalogs(items: items, champions: champions)
        }
        recomputeHistoryStats()
        refreshCatalogsFromNetwork()
    }

    func refreshCatalogsFromNetwork() {
        guard let dataDragon, catalogTask == nil else { return }
        catalogTask = Task { [weak self] in
            defer { self?.catalogTask = nil }
            guard let version = try? await dataDragon.latestVersion(), version != self?.itemCatalog?.version,
                  let items = try? await dataDragon.items(version: version),
                  let champions = try? await dataDragon.champions(version: version) else { return }
            await self?.installCatalogs(items: items, champions: champions)
        }
    }
}


private extension Coordinator {
    var lcuReportsGameAlive: Bool { lcuPhase.map { Self.gameAlivePhases.contains($0) } ?? false }
    var lcuReportsGameStarted: Bool { lcuPhase == .inProgress || lcuPhase == .gameStart }

    func beginClientSession() {
        clientSessionStart = now()
        client = nil
        tiltFetchedForClient = false
        refreshCatalogsFromNetwork()
    }

    func handleGameProcessExit() {
        guard let game = session, game.lastSnapshot != nil else { return }
        if game.ended || !clientRunning {
            finalize()
            return
        }
        // crash or quit mid-game: keep the game, hide the overlay, wait for reconnect or the client.
        game.suspended = true
        snapshot = nil
    }

    /// starts and stops the loops for the current process and client state, then derives the phase.
    func reconcile() {
        defer { syncReview() }
        guard clientRunning || gameRunning else {
            goToSleep()
            return
        }
        if clientRunning {
            if clientTask == nil { startClientLoop() }
        } else {
            stopClientLoop()
        }
        let wantLive = (gameRunning || lcuReportsGameAlive) && !finishedLatch
        if wantLive {
            if liveTask == nil { startLiveLoop() }
        } else {
            stopLiveLoop()
        }
        let next = nextPhase(wantLive: wantLive)
        if phase != next { phase = next }
    }

    func goToSleep() {
        if session != nil { finalize() }
        stopClientLoop()
        stopLiveLoop()
        prefetchTask?.cancel()
        prefetchTask = nil
        finishedLatch = false
        phase = .asleep
    }

    func nextPhase(wantLive: Bool) -> AppPhase {
        if let game = session, game.suspended { return .client(lcuPhase ?? .reconnect) }
        if wantLive && (liveResponding || session != nil || lcuReportsGameStarted) { return .inGame }
        if finishedLatch { return .postGame }
        return .client(lcuPhase ?? .none)
    }

    func handlePhase(_ p: GameflowPhase) {
        lcuPhase = p
        if Self.postGamePhases.contains(p) { awaitingPostGameRefresh = true }
        if Self.preGamePhases.contains(p) { enterPreGame() }
        if let game = session, game.suspended, !Self.gameAlivePhases.contains(p) { finalize() }
        if !tiltFetchedForClient { refreshTilt() }
        reconcile()
    }

    func enterPreGame() {
        finishedLatch = false
        // the client adds the finished game to match history only after the end-of-game screen, so the
        // fetch in `finalize()` can miss it: fetch once more now (once per game end).
        guard awaitingPostGameRefresh else { return }
        awaitingPostGameRefresh = false
        refreshTilt()
    }

    func handleChampSelect(_ info: ChampSelectInfo?) {
        guard let info, info != champSelectInfo else { return }
        champSelectInfo = info
        guard let key = info.championKey, let champion = championCatalog?.champion(key: key) else { return }
        prefetchBaseBuild(for: champion, role: info.role)
    }

    func prefetchBaseBuild(for champion: DDChampion, role: Role?) {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBase = nil
        guard settings.useOPGG, let buildSource else { return }
        let championID = champion.id
        let role = role ?? Self.defaultRole(for: ChampionArchetype(champion: champion))
        prefetchTask = Task { [weak self] in
            let build = await buildSource.baseBuild(championID: championID, role: role)
            guard !Task.isCancelled else { return }
            self?.prefetchedBase = build
        }
    }
}


private extension Coordinator {
    func startClientLoop() {
        clientTask = pollingTask(every: Self.clientPollInterval) { await $0.clientTick() }
    }

    func startLiveLoop() {
        notRunningStreak = 0
        liveTask = pollingTask(every: Self.livePollInterval) { await $0.liveTick() }
    }

    func stopClientLoop() {
        clientTask?.cancel()
        clientTask = nil
    }

    func stopLiveLoop() {
        liveTask?.cancel()
        liveTask = nil
        liveResponding = false
        notRunningStreak = 0
    }

    /// runs `tick` then sleeps, until cancelled or the coordinator is gone; holds no strong reference while asleep.
    func pollingTask(every interval: Duration,
                     tick: @escaping @MainActor (Coordinator) async -> Void) -> Task<Void, Never> {
        let sleep = self.sleep
        return Task { [weak self] in
            while !Task.isCancelled {
                if let coordinator = self { await tick(coordinator) } else { return }
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    func clientTick() async {
        if client == nil { client = makeClient() }
        guard let client else { return }
        let p: GameflowPhase
        do {
            p = try await client.phase()
        } catch {
            // stale credentials / client restarting: rediscover next tick.
            if !Task.isCancelled { self.client = nil }
            return
        }
        guard !Task.isCancelled else { return }
        handlePhase(p)
        guard p == .champSelect, let info = try? await client.champSelect(), !Task.isCancelled else { return }
        handleChampSelect(info)
    }

    func liveTick() async {
        do {
            let s = try await live.fetch()
            guard !Task.isCancelled else { return }
            handleSnapshot(s)
        } catch let error as LiveClientError {
            guard !Task.isCancelled else { return }
            switch error {
            case .notReady: handleNotReady()
            case .notRunning: handleNotRunning()
            case .badPayload: break
            }
        } catch {
            // other transport errors: try again next tick.
        }
    }
}


private extension Coordinator {
    func handleNotReady() {
        notRunningStreak = 0
        guard !liveResponding else { return }
        liveResponding = true
        reconcile()
    }

    func handleNotRunning() {
        guard let game = session, game.lastSnapshot != nil, !game.suspended else {
            if liveResponding {
                liveResponding = false
                reconcile()
            }
            return
        }
        notRunningStreak += 1
        // while the game process is alive a silent api is a stall or hitch, not the end of the game: keep the
        // game until game end or the process exits (league process changed).
        guard game.ended || (!gameRunning && notRunningStreak >= Self.reconnectGracePolls) else { return }
        finalize()
        reconcile()
    }

    func handleSnapshot(_ s: LiveGameSnapshot) {
        notRunningStreak = 0
        guard s.isReady, let me = s.me else {
            handleNotReady()
            return
        }
        // summoner's rift (and the unrecorded practice tool) only: other modes (aram, arena, custom maps) get no session, so no goal result, death
        // review or history entry.
        guard s.hasLiveFeatures else {
            if session != nil { finalize() }
            liveResponding = true
            reconcile()
            return
        }
        let gameTime = s.gameData?.gameTime ?? 0
        guard let game = trackedSession(for: s, me: me, gameTime: gameTime) else { return }
        game.ingest(s, gameTime: gameTime)
        liveResponding = true
        if s != snapshot {
            snapshot = s
            recompute(game)
        }
        reconcile()
    }

    /// the session `s` belongs to: a different game finalizes the current one first, then a new session opens.
    /// nil for a finished game the api still serves (post-game screen).
    func trackedSession(for s: LiveGameSnapshot, me: Player, gameTime: Double) -> GameSession? {
        let roster = Self.rosterKey(s)
        if let game = session {
            if game.continues(roster: roster, gameTime: gameTime) { return game }
            finalize()
        }
        if finishedLatch, roster == lastFinishedRoster { return nil }
        finishedLatch = false
        let game = newSession(s, me: me, roster: roster, gameTime: gameTime)
        session = game
        goalProgress = nil
        return game
    }

    func newSession(_ s: LiveGameSnapshot, me: Player, roster: String, gameTime: Double) -> GameSession {
        let start = Date(timeIntervalSince1970: (now().timeIntervalSince1970 - gameTime).rounded())
        let champion = Self.champion(of: me, in: championCatalog)
        let championID = champion?.id ?? me.championID
        return GameSession(id: "\(Int(start.timeIntervalSince1970))-\(championID)", startDate: start,
                           champion: championID, role: sessionRole(me: me, champion: champion),
                           rosterKey: roster, gameTime: gameTime)
    }

    /// champ select pick when it matches the champion in game, else the live position, else the archetype default.
    func sessionRole(me: Player, champion: DDChampion?) -> Role? {
        if let info = champSelectInfo, let key = info.championKey, champion?.key == key, let role = info.role {
            return role
        }
        if let role = me.position.flatMap({ Role(livePosition: $0) }) { return role }
        return champion.map { Self.defaultRole(for: ChampionArchetype(champion: $0)) }
    }

    static func champion(of player: Player, in catalog: ChampionCatalog?) -> DDChampion? {
        catalog?.champion(id: player.championID) ?? catalog?.champion(displayName: player.championName)
    }
}


private extension Coordinator {
    func recompute(_ game: GameSession) {
        guard let s = snapshot else { return }
        if let engine { updateBuildOutputs(game, snapshot: s, engine: engine) }
        // independent of the engine; assign only on change so an unchanged line never invalidates observers.
        let line = settings.showJunglerLine ? game.jungler.update(s) : nil
        if line != jungler { jungler = line }
        updateGoal(game)
    }

    func updateBuildOutputs(_ game: GameSession, snapshot s: LiveGameSnapshot, engine: CounterBuildEngine) {
        let gameTime = s.gameData?.gameTime ?? 0
        threat = ThreatProfile.analyze(enemies: s.enemies, catalog: engine.catalog, champions: engine.champions,
                                       gameTime: gameTime, classifier: engine.classifier)
        ensureBaseBuild(game, snapshot: s, engine: engine)
        suggestion = engine.suggest(snapshot: s, base: game.base, previous: suggestion)
        let alerts = game.spikes.update(s, catalog: engine.catalog)
        game.logSpikes(alerts, at: gameTime)
        enqueueSpikes(alerts)
    }

    func updateGoal(_ game: GameSession) {
        if let latched = game.goalLatched {
            goalProgress = latched
            return
        }
        guard let s = game.lastSnapshot, let goal = settings.effectiveGoal() else {
            goalProgress = nil
            return
        }
        let progress = GoalTracker.evaluate(goal, snapshot: s, catalog: itemCatalog, final: false)
        if progress.state == .achieved || progress.state == .failed { game.goalLatched = progress }
        goalProgress = progress
    }

    /// template immediately; op.gg (prefetched in champ select or fetched now) replaces it when it arrives.
    func ensureBaseBuild(_ game: GameSession, snapshot s: LiveGameSnapshot, engine: CounterBuildEngine) {
        guard let me = s.me else { return }
        let champion = Self.champion(of: me, in: engine.champions)
        let championID = champion?.id ?? me.championID
        guard game.base?.champion != championID else { return }
        if let prefetched = prefetchedBase, prefetched.champion == championID {
            setBaseBuild(prefetched, for: game)
            return
        }
        let role = game.role ?? .mid
        let catalog = engine.catalog
        let template = champion.map {
            ClassTemplates.baseBuild(for: $0, role: role, catalog: catalog, patch: catalog.version)
        } ?? ClassTemplates.baseBuild(archetype: .fighter, champion: championID, role: role, catalog: catalog,
                                      patch: catalog.version)
        setBaseBuild(template, for: game)
        fetchOPGGBuild(for: game, championID: championID, role: role)
    }

    func fetchOPGGBuild(for game: GameSession, championID: String, role: Role) {
        guard settings.useOPGG, let buildSource, game.baseFetch == nil else { return }
        game.baseFetch = Task { [weak self, weak game] in
            guard let build = await buildSource.baseBuild(championID: championID, role: role), !Task.isCancelled,
                  let self, let game, self.session === game else { return }
            self.setBaseBuild(build, for: game)
            if self.snapshot != nil { self.recompute(game) }
        }
    }

    func setBaseBuild(_ build: BaseBuild, for game: GameSession) {
        game.base = build
        baseBuild = build
    }

    func enqueueSpikes(_ alerts: [SpikeAlert]) {
        guard !alerts.isEmpty else { return }
        spikeQueue.append(contentsOf: alerts)
        showNextSpike()
    }

    func showNextSpike() {
        guard spikeAlerts.isEmpty, !spikeQueue.isEmpty else { return }
        let alert = spikeQueue.removeFirst()
        spikeAlerts = [alert]
        spikeHistory.append(alert)
        if spikeHistory.count > Self.spikeHistoryLimit { spikeHistory.removeFirst() }
        let sleep = self.sleep
        spikeTask = Task { [weak self] in
            do { try await sleep(Self.spikeAlertDuration) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.spikeAlerts = []
            self.spikeTask = nil
            self.showNextSpike()
        }
    }

    func clearLiveOutputs() {
        snapshot = nil
        suggestion = nil
        threat = nil
        jungler = nil
        baseBuild = nil
        spikeTask?.cancel()
        spikeTask = nil
        spikeQueue = []
        spikeAlerts = []
    }
}


private extension Coordinator {
    /// builds and stores the record, posts the review, refreshes tilt. does not touch loops (call `reconcile`).
    func finalize() {
        guard let game = session else { return }
        session = nil
        game.baseFetch?.cancel()
        guard let last = game.lastSnapshot else { return }
        if last.isPracticeTool {
            resetAfterGame(game, goalResult: nil)
            return
        }
        let record = game.makeRecord(finalSnapshot: last, goal: settings.effectiveGoal(), catalog: itemCatalog)
        save(record)
        // shown by sync review once the game process has exited and the end-of-game flow is on screen.
        reviewCandidateID = record.deaths.isEmpty ? nil : record.id
        resetAfterGame(game, goalResult: record.goalResult)
    }

    func save(_ record: GameRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist { store in await store.append(record) }
        recomputeHistoryStats()
    }

    func resetAfterGame(_ game: GameSession, goalResult: GoalProgress?) {
        clearLiveOutputs()
        goalProgress = goalResult
        finishedLatch = true
        lastFinishedRoster = game.rosterKey
        liveResponding = false
        notRunningStreak = 0
        prefetchedBase = nil
        champSelectInfo = nil
        refreshTilt()
    }

    /// applies review lifecycle after every phase evaluation: shows the review of the finished game once the end
    /// flow is on screen and the game process has exited; closes it when the flow is left or league exits.
    func syncReview() {
        guard let id = reviewCandidateID, !ReviewLifecycle.shouldClose(phase: phase) else {
            closeReview()
            return
        }
        guard let record = records.first(where: { $0.id == id }), pendingReview?.id != id,
              ReviewLifecycle.shouldShow(phase: phase, hasReviewableRecord: !record.deaths.isEmpty,
                                         gameProcessRunning: gameRunning) else { return }
        pendingReview = record
    }

    func closeReview() {
        reviewCandidateID = nil
        if pendingReview != nil { pendingReview = nil }
    }
}


private extension Coordinator {
    func refreshTilt() {
        guard let client else { return }
        tiltFetchedForClient = true
        tiltTask?.cancel()
        tiltTask = Task { [weak self] in
            let recent = try? await client.recentMatches(count: Self.recentMatchCount)
            guard !Task.isCancelled, let self else { return }
            guard let recent else {
                self.tiltFetchedForClient = false   // retry on the next client tick
                return
            }
            self.matches = recent
            self.evaluateTilt()
        }
    }

    func evaluateTilt() {
        guard let matches else { return }
        let status = TiltGuard.evaluate(matches: matches, sessionStart: clientSessionStart, now: now(),
                                        settings: settings.tilt)
        tilt = status
        let kind: String? = switch status.reason {
        case .lossStreak?: "lossStreak"
        case .longSession?: "longSession"
        case nil: nil
        }
        if let kind, kind != lastNudgeKind, let message = status.message { onTiltNudge?(message) }
        lastNudgeKind = kind
    }

    func recomputeHistoryStats() {
        let stats = HistoryStats(records: records)
        goalStreak = stats.goalStreak
        lastSession = stats.lastSession
        deathCauseStats = stats.deathCauses
    }

    /// store writes run one after another, in call order.
    func persist(_ operation: @escaping @Sendable (Store) async -> Void) {
        let store = self.store
        let previous = persistTask
        persistTask = Task {
            await previous?.value
            await operation(store)
        }
    }
}
