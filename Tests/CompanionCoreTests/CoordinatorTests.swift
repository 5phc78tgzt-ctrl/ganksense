import Testing
@testable import CompanionCore

// no foundation import here: see coordinatortestsupport.swift.

/// polls `condition` every 1 ms of real time, up to the timeout.
@MainActor
private func eventually(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<timeoutMs {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
private func realSleep(ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

@MainActor
@Suite struct CoordinatorTests {
    @Test func endOfGameCreatesRecordWithDeaths() async throws {
        let store = makeTempStore()
        let c = Coordinator.demo(store: store, clock: FastClock())
        var nudges: [String] = []
        c.onTiltNudge = { nudges.append($0) }
        c.start()
        c.leagueProcessChanged(clientRunning: true, gameRunning: true)
        #expect(await eventually { c.records.count == 1 })
        // the review waits for the game process to exit, so it never floats over the game
        #expect(c.pendingReview == nil)
        c.leagueProcessChanged(clientRunning: true, gameRunning: false)
        let r = try #require(c.pendingReview)
        #expect(r.champion == "Jinx")
        #expect(r.role == .adc)
        #expect(r.deaths.map(\.killer) == ["Zed", "Draven"])
        #expect(r.deaths.last?.assisters == ["Soraka"])
        #expect(r.win == false)
        #expect(!r.isVoid)
        #expect(r.durationSec == 900)
        #expect(r.goalResult?.state == .achieved)
        #expect(c.records.count == 1)
        #expect(c.goalStreak == 1)
        #expect(c.lastSession?.losses == 1)
        #expect(c.snapshot == nil && c.suggestion == nil)
        // back to the lobby after the end-of-game screen, without a second record
        #expect(await eventually { c.phase == .client(.lobby) })
        #expect(c.records.count == 1)
        // demo history now has 3 losses in a row, so one tilt nudge
        #expect(await eventually { c.tilt?.reason == .lossStreak(3) })
        #expect(nudges.count == 1)

        // the review closes by itself once the end-of-game flow is left, but the record stays reviewable
        #expect(c.pendingReview == nil)
        #expect(c.latestReviewableRecord?.id == r.id)
        // death causes feed the insight stats (2 deaths analysed)
        #expect(c.deathCauseStats.values.reduce(0, +) == 2)
        await c.flushPersistence()
        let stored = await store.records()
        #expect(stored.count == 1)
        #expect(stored.first?.context != nil)
        c.dismissReview()
        #expect(c.pendingReview == nil)
        c.stop()
    }

    @Test func storedDeathsHoldChampionNamesNotRiotIDs() async throws {
        var snap = try midgame(time: 900)
        snap.events = [
            GameEvent(id: 3, name: "ChampionKill", time: 410.5, killer: "ZedGod#NA1", victim: "poopdog#swag"),
            GameEvent(id: 7, name: "ChampionKill", time: 655, killer: "DravenKing#NA1", victim: "poopdog#swag",
                      assisters: ["SorakaHeal#NA1", "Stranger#0001"]),
        ]
        var end = snap
        end.events.append(GameEvent(id: 99, name: "GameEnd", time: 910, result: "Lose"))
        let live = ScriptedLive([.snap(snap), .snap(end)], then: .notRunning)
        let store = makeTempStore()
        let c = makeCoordinator(live: live, store: store)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { c.records.count == 1 })
        await c.flushPersistence()
        let stored = try #require(await store.records().first)
        #expect(stored.deaths.map(\.killer) == ["Zed", "Draven"])
        // an assister matching nobody on the playerlist is dropped, not kept raw
        #expect(stored.deaths[1].assisters == ["Soraka"])
        let json = jsonString(stored)
        for riotID in ["ZedGod", "DravenKing", "SorakaHeal", "Stranger", "poopdog", "#NA1", "#swag"] {
            #expect(!json.contains(riotID))
        }
        c.stop()
    }

    @Test func remakeIsVoid() async throws {
        let remake = try midgame(time: 180, ended: true, result: "Lose")
        let live = ScriptedLive([.snap(try midgame(time: 170)), .snap(remake)], then: .notRunning)
        let c = makeCoordinator(live: live)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.setGoal(Goal(preset: .totalDeaths, target: 5))
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { c.records.count == 1 })
        let r = try #require(c.records.first)
        #expect(r.isVoid)
        #expect(r.goalResult == nil)
        #expect(c.goalStreak == 0)
        #expect(c.lastSession == nil)
        // the game process still reports running, but the finished game is not polled again
        #expect(c.phase == .postGame)
        #expect(await eventually { !c.hasActiveLoops })
        c.stop()
    }

    @Test func reconnectDoesNotDuplicateDeaths() async throws {
        let a = try midgame(time: 900), b = try midgame(time: 905)
        let end = try midgame(time: 910, ended: true)
        // a blip of 3 polls (under 10 s) without the api, then the same events again
        let live = ScriptedLive([.snap(a), .snap(a), .notRunning, .notRunning, .notRunning, .snap(b), .snap(b),
                                 .snap(end)], then: .notRunning)
        let c = makeCoordinator(live: live)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { c.records.count == 1 })
        #expect(c.records[0].deaths.map(\.id) == [3, 7])
        #expect(c.records[0].win == true)
        #expect(c.records[0].durationSec == 910)
        await realSleep(ms: 10)
        #expect(c.records.count == 1)
        c.stop()
    }

    @Test func crashAndReconnectKeepsOneGame() async throws {
        let live = ControlledLive()
        let client = FakeClient()
        client.set(.inProgress)
        let c = makeCoordinator(live: live, client: client)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        live.set(.snap(try midgame(time: 900)))
        c.leagueProcessChanged(clientRunning: true, gameRunning: true)
        #expect(await eventually { c.snapshot != nil && c.suggestion != nil })
        let firstID = c.snapshot.map(Coordinator.rosterKey)

        // game process dies and the client offers a reconnect: overlay data hidden, game kept
        live.set(.notRunning)
        client.set(.reconnect)
        c.leagueProcessChanged(clientRunning: true, gameRunning: false)
        #expect(c.snapshot == nil)
        #expect(await eventually { c.phase == .client(.reconnect) })
        // the live loop keeps probing (client says reconnect) for longer than the 10-poll grace
        let before = live.calls
        #expect(await eventually { live.calls >= before + Coordinator.reconnectGracePolls + 2 })
        #expect(c.records.isEmpty)
        #expect(c.snapshot == nil)

        // reconnected with the same roster and events
        live.set(.snap(try midgame(time: 960)))
        client.set(.inProgress)
        c.leagueProcessChanged(clientRunning: true, gameRunning: true)
        #expect(await eventually { c.snapshot?.gameData?.gameTime == 960 && c.phase == .inGame })
        #expect(c.snapshot.map(Coordinator.rosterKey) == firstID)

        live.set(.snap(try midgame(time: 1000, ended: true)))
        #expect(await eventually { c.snapshot?.gameData?.gameTime == 1000 })
        live.set(.notRunning)
        #expect(await eventually { c.records.count == 1 })
        #expect(c.records[0].deaths.count == 2)
        c.leagueProcessChanged(clientRunning: true, gameRunning: false)
        client.set(.endOfGame)
        await realSleep(ms: 10)
        #expect(c.records.count == 1)
        #expect(c.phase == .postGame)
        client.set(.lobby)
        #expect(await eventually { c.phase == .client(.lobby) })
        c.stop()
    }

    @Test func graceEndsGameWithoutGameEnd() async throws {
        // no game process (only the client says the game is in progress): the grace period ends the game
        let live = ScriptedLive([.snap(try midgame(time: 900))], then: .notRunning)
        let client = FakeClient()
        client.set(.inProgress)
        let c = makeCoordinator(live: live, client: client)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: true, gameRunning: false)
        #expect(await eventually { c.records.count == 1 })
        #expect(live.calls >= 1 + Coordinator.reconnectGracePolls)
        #expect(c.records[0].win == nil)
        #expect(c.records[0].deaths.count == 2)
        c.stop()
    }

    @Test func apiStallKeepsRunningGame() async throws {
        // the game process is alive but the api stops answering for far longer than the grace
        let live = ControlledLive()
        live.set(.snap(try midgame(time: 900)))
        let c = makeCoordinator(live: live)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { c.snapshot != nil })
        live.set(.notRunning)
        let before = live.calls
        #expect(await eventually { live.calls >= before + Coordinator.reconnectGracePolls * 3 })
        #expect(c.records.isEmpty)
        #expect(c.pendingReview == nil)
        #expect(c.phase == .inGame)
        // the api comes back and the same game continues
        live.set(.snap(try midgame(time: 960)))
        #expect(await eventually { c.snapshot?.gameData?.gameTime == 960 })
        #expect(c.records.isEmpty)
        c.stop()
    }

    @Test func otherModesRecordNothing() async throws {
        var aram = try midgame(time: 900)
        aram.gameData?.gameMode = "ARAM"
        aram.gameData?.mapNumber = 12
        let live = ControlledLive()
        live.set(.snap(aram))
        let c = makeCoordinator(live: live)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { live.calls >= 5 })
        #expect(c.snapshot == nil && c.goalProgress == nil && c.suggestion == nil)
        var ended = aram
        ended.events.append(GameEvent(id: 99, name: "GameEnd", time: 950, result: "Win"))
        live.set(.snap(ended))
        #expect(await eventually { live.calls >= 10 })
        c.leagueProcessChanged(clientRunning: false, gameRunning: false)
        #expect(c.records.isEmpty)
        #expect(c.pendingReview == nil)
        c.stop()
    }

    @Test func gameExitWithoutClientFinalizes() async throws {
        let live = ControlledLive()
        live.set(.snap(try midgame(time: 900)))
        let c = makeCoordinator(live: live)
        c.start()
        #expect(await eventually { c.itemCatalog != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: true)
        #expect(await eventually { c.snapshot != nil })
        c.leagueProcessChanged(clientRunning: false, gameRunning: false)
        #expect(c.records.count == 1)
        #expect(c.phase == .asleep)
        #expect(c.snapshot == nil)
        #expect(!c.hasActiveLoops)
        // league is gone: no review floats on screen, but the last game stays reviewable
        #expect(c.pendingReview == nil)
        #expect(c.latestReviewableRecord?.deaths.count == 2)
        c.stop()
    }

    @Test func storeRoundTripAndCorruptFile() async throws {
        let store = makeTempStore()
        #expect(await store.loadSettings() == Settings())
        #expect(await store.records().isEmpty)

        var s = Settings()
        s.goal = Goal(preset: .csAt10, target: 80)
        s.setTarget(60, for: .goldAt15)
        s.overlayCorner = .leftUpper
        s.showWhileHoldingTab = false
        s.tilt.lossStreak = 4
        await store.save(s)
        await store.append(sampleRecord())
        var updated = sampleRecord()
        updated.deaths[1].assisters = ["Soraka", "Leona"]
        await store.update(updated)
        #expect(await Store(directory: store.directory).records() == [updated])
        await store.append(sampleRecord()) // same id replaces, never duplicates

        let reopened = Store(directory: store.directory)
        #expect(await reopened.loadSettings() == s)
        #expect(await reopened.records() == [sampleRecord()])

        #expect(s.effectiveGoal()?.target == 80)
        #expect(s.target(for: .goldAt15) == 60)
        #expect(s.target(for: .csAt10) == 70)

        writeGarbage(store, file: "settings.json")
        writeGarbage(store, file: "records.json")
        let corrupt = Store(directory: store.directory)
        #expect(await corrupt.loadSettings() == Settings())
        #expect(await corrupt.records().isEmpty)
        #expect(backupCount(store) == 1)

        // one bad record does not take the rest of the history with it
        writeRecordsWithOneBad(store, good: sampleRecord())
        let mixed = Store(directory: store.directory)
        #expect(await mixed.records() == [sampleRecord()])
        #expect(backupCount(store) >= 1)

        // missing keys keep defaults, unknown keys are ignored
        let partial = decodeSettings(#"{"overlayScale": 1.2, "futureKey": true, "tilt": {"lossStreak": 2, "sessionHours": 3, "enabled": false}}"#)
        #expect(partial?.overlayScale == 1.2)
        #expect(partial?.overlayEnabled == true)
        #expect(partial?.tilt.enabled == false)
        #expect(partial?.showWhileHoldingTab == true)
    }
}
