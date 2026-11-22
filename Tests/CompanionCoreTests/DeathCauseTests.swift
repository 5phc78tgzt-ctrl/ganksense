import Testing
@testable import CompanionCore

@MainActor
private func settled(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<timeoutMs {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private let me = "Jinx"

private func roster() -> [GameContext.Participant] {
    [
        .init(champion: me, isMe: true, isAlly: true, spells: ["Heal", "Flash"], position: "BOTTOM"),
        .init(champion: "Lux", isAlly: true, spells: ["Flash", "Ignite"], position: "UTILITY"),
        .init(champion: "Sejuani", isAlly: true, spells: ["Smite", "Flash"], position: "JUNGLE"),
        .init(champion: "Draven", isAlly: false, spells: ["Flash", "Heal"], position: "BOTTOM"),
        .init(champion: "Leona", isAlly: false, spells: ["Flash", "Ignite"], position: "UTILITY"),
        .init(champion: "Zed", isAlly: false, spells: ["Flash", "Ignite"], position: "MIDDLE"),
        .init(champion: "Lee Sin", isAlly: false, spells: ["Smite", "Flash"], position: "JUNGLE"),
    ]
}

private func kill(_ id: Int, _ time: Double, _ killer: String, _ victim: String, _ assisters: [String] = []) -> GameContext.LoggedEvent {
    .init(id: id, name: "ChampionKill", time: time, killer: killer, victim: victim, assisters: assisters)
}

private func analyse(_ events: [GameContext.LoggedEvent], spikes: [GameContext.Spike] = []) -> [DeathAnalysis] {
    let ctx = GameContext(participants: roster(), events: events, spikes: spikes)
    let deaths = events.filter { $0.victim == me }.map {
        DeathEvent(id: $0.id, time: $0.time, killer: $0.killer, assisters: $0.assisters)
    }
    return DeathAnalyzer.analyze(deaths: deaths, context: ctx)
}

@Suite struct DeathCauseTests {
    @Test func junglerGank() {
        let a = analyse([kill(1, 500, "Lee Sin", me, ["Draven"])])
        #expect(a[0].primary == .junglerGank)
        #expect(a[0].evidence.contains("Lee Sin"))
        #expect(a[0].confidence == .high)
    }

    @Test func teamfight() {
        let a = analyse([kill(1, 600, "Draven", "Lux"), kill(2, 604, "Leona", me, ["Draven"]), kill(3, 608, "Zed", "Sejuani")])
        #expect(a[0].primary == .teamfight)
        #expect(a[0].evidence.contains("2 other champions"))
    }

    @Test func unclearWhenNothingStandsOut() {
        let a = DeathAnalyzer.analyze(deaths: [DeathEvent(id: 1, time: 1_000, killer: nil)],
                                      context: GameContext(participants: roster(), events: []))
        #expect(a[0].primary == .unclear)
        #expect(a[0].title == "Unclear")
        #expect(a[0].evidence.contains("no clear signal"))
    }
}

@Suite struct ReviewLifecycleTests {
    @Test(arguments: [GameflowPhase.waitingForStats, .preEndOfGame, .endOfGame])
    func showsInTheEndFlow(_ p: GameflowPhase) {
        #expect(ReviewLifecycle.shouldShow(phase: .client(p), hasReviewableRecord: true, gameProcessRunning: false))
        #expect(!ReviewLifecycle.shouldClose(phase: .client(p)))
    }

    @Test func needsDeathsAndAnExitedGame() {
        #expect(!ReviewLifecycle.shouldShow(phase: .postGame, hasReviewableRecord: false, gameProcessRunning: false))
        #expect(!ReviewLifecycle.shouldShow(phase: .postGame, hasReviewableRecord: true, gameProcessRunning: true))
    }

    @Test(arguments: [GameflowPhase.lobby, .none, .champSelect, .readyCheck, .matchmaking, .inProgress])
    func closesWhenTheFlowIsLeft(_ p: GameflowPhase) {
        #expect(ReviewLifecycle.shouldClose(phase: .client(p)))
        #expect(!ReviewLifecycle.shouldShow(phase: .client(p), hasReviewableRecord: true, gameProcessRunning: false))
    }

    @Test func closesWhenLeagueExitsAndNeverShowsInGame() {
        #expect(ReviewLifecycle.shouldClose(phase: .asleep))
        #expect(ReviewLifecycle.shouldClose(phase: .inGame))
        #expect(ReviewLifecycle.shouldCloseManual(phase: .inGame))
        #expect(!ReviewLifecycle.shouldCloseManual(phase: .asleep))
        #expect(!ReviewLifecycle.shouldCloseManual(phase: .client(.lobby)))
    }
}

@Suite struct PrivacyTests {
    @Test func purgeRemovesHistoryAndKeepsSettings() async {
        let store = makeTempStore()
        var s = Settings(); s.overlayScale = 1.3
        await store.save(s)
        await store.append(sampleRecord())
        writeFile(store, file: "records.corrupt-1.json", "[]")
        await store.purgeHistory()
        #expect(await store.records().isEmpty)
        #expect(!fileNames(store).contains("records.json"))
        #expect(!fileNames(store).contains("records.corrupt-1.json"))
        #expect(await Store(directory: store.directory).loadSettings().overlayScale == 1.3)
    }

    @MainActor @Test func coordinatorPurgeResetsLiveState() async throws {
        let store = makeTempStore()
        await store.append(sampleRecord())
        let c = makeCoordinator(live: ControlledLive(), store: store)
        c.start()
        #expect(await settled { c.records.count == 1 })
        #expect(c.latestReviewableRecord != nil)
        c.purgeHistory()
        #expect(c.records.isEmpty)
        #expect(c.latestReviewableRecord == nil)
        #expect(c.pendingReview == nil)
        #expect(c.deathCauseStats.isEmpty)
        await c.flushPersistence()
        #expect(await store.records().isEmpty)
        c.stop()
    }
}
