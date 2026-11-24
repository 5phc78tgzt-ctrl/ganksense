import Testing
@testable import CompanionCore

@Test func csAt10FailedAfterDeadline() {
    let s = goalSnapshot(time: 610, cs: 50)
    let g = Goal(preset: .csAt10, target: 70)
    #expect(GoalTracker.evaluate(g, snapshot: s, catalog: nil, final: false).state == .failed)
    let good = goalSnapshot(time: 610, cs: 75)
    #expect(GoalTracker.evaluate(g, snapshot: good, catalog: nil, final: false).state == .achieved)
}

@Test func csAt10BehindPaceIsUndecidedNotFailed() {
    let s = goalSnapshot(time: 480, cs: 30)
    let p = GoalTracker.evaluate(Goal(preset: .csAt10, target: 70), snapshot: s, catalog: nil, final: false)
    #expect(p.state == .pending)
    let fin = GoalTracker.evaluate(Goal(preset: .csAt10, target: 70), snapshot: s, catalog: nil, final: true)
    #expect(fin.state == .failed)
}

@Test func csAt10LateFirstLookInterpolatesToTheDeadline() {
    // 66 cs at 9:50, 76 at 10:10: the deadline value is 71 (achieved), not the raw 76 scaled by pace.
    let g = Goal(preset: .csAt10, target: 70)
    let late = goalSnapshot(time: 610, cs: 76)
    let p = GoalTracker.evaluate(g, snapshot: late, catalog: nil, final: false, before: (590, 66))
    #expect(p.current.rounded() == 71)
    #expect(p.state == .achieved)
    let slow = GoalTracker.evaluate(g, snapshot: goalSnapshot(time: 610, cs: 70), catalog: nil, final: false,
                                    before: (590, 60))
    #expect(slow.state == .failed)
}

@Test func totalDeathsLocksAtFinal() {
    let g = Goal(preset: .totalDeaths, target: 5)
    let s = goalSnapshot(time: 1800, deaths: 3)
    #expect(GoalTracker.evaluate(g, snapshot: s, catalog: nil, final: false).state == .onTrack)
    #expect(GoalTracker.evaluate(g, snapshot: s, catalog: nil, final: true).state == .achieved)
    let bad = goalSnapshot(time: 1800, deaths: 6)
    #expect(GoalTracker.evaluate(g, snapshot: bad, catalog: nil, final: false).state == .failed)
}

@Suite struct OverlayVisibilityTests {
    @Test func tabGateOnlyInRunningGameWithLeagueInFront() {
        func gate(_ phase: AppPhase, snap: Bool = true, front: Bool = true, on: Bool = true) -> Bool {
            TabGate.isActive(phase: phase, hasActiveSnapshot: snap, gameFrontmost: front, enabled: on)
        }
        #expect(!gate(.asleep))
        #expect(!gate(.client(.none)))
        #expect(!gate(.client(.lobby)))
        #expect(!gate(.client(.champSelect)))
        #expect(!gate(.client(.inProgress)))
        #expect(!gate(.postGame))
        #expect(!gate(.inGame, front: false))        // another app or the client is in front
        #expect(!gate(.inGame, snap: false))         // loading screen
        #expect(!gate(.inGame, on: false))           // setting off
        #expect(gate(.inGame))                       // game and frontmost
    }

    @Test func loadingScreenSnapshotDoesNotCount() {
        #expect(!TabGate.isActiveSnapshot(nil))
        var s = LiveGameSnapshot(gameData: GameData(gameMode: "CLASSIC", gameTime: 0, mapNumber: 11))
        #expect(!TabGate.isActiveSnapshot(s))
        s.gameData?.gameTime = 12
        #expect(TabGate.isActiveSnapshot(s))
    }

    @Test func tabFilterDebouncesAndIgnoresModifiers() {
        var f = TabHoldFilter()
        func sample(_ tab: Bool, _ mod: Bool) -> Bool { f.sample(tabDown: tab, modifierDown: mod) }
        // held since before sampling started (loading screen): ignored until released
        #expect(!sample(true, false))
        #expect(!sample(true, false))
        _ = sample(false, false)
        // fresh press shows at once
        #expect(sample(true, false))
        // one missed sample does not flicker, two hide
        #expect(sample(false, false))
        #expect(sample(true, false))
        #expect(sample(false, false))
        #expect(!sample(false, false))
        // cmd-tab is ignored, and stays ignored after cmd is released while tab is still down
        #expect(!sample(true, true))
        #expect(!sample(true, false))
        _ = sample(false, false)
        #expect(sample(true, false))
        // a modifier pressed during a tab hold hides it
        #expect(!sample(true, true))
    }
}

@Test func csBenchmarkFollowsChosenMinute() {
    let g = Goal(preset: .csAt10, target: 60, minutes: 8)
    #expect(g.title == "CS at 8:00")
    let ahead = GoalTracker.evaluate(g, snapshot: goalSnapshot(time: 300, cs: 40), catalog: nil, final: false)
    #expect(ahead.state == .onTrack)
    #expect(ahead.label == "40 / 60 CS \u{B7} 5:00")
    let behind = GoalTracker.evaluate(g, snapshot: goalSnapshot(time: 300, cs: 20), catalog: nil, final: false)
    #expect(behind.state == .pending)
    #expect(GoalTracker.evaluate(g, snapshot: goalSnapshot(time: 490, cs: 59), catalog: nil, final: false).state == .failed)
}

@Test func oldSettingsDecodeWithDefaultMinutes() throws {
    let json = #"{"goal":{"preset":"csAt10","target":75},"goalTargets":{"csAt10":75}}"#
    let s = try #require(decodeSettings(json))
    #expect(s.goal?.minutes == 10)
    #expect(s.effectiveGoal()?.minutes == 10)
    #expect(s.goalMinutes.isEmpty)
    var m = s
    m.setMinutes(12, for: .csAt10)
    #expect(m.effectiveGoal()?.minutes == 12)
    #expect(m.minutes(for: .totalDeaths) == nil)
}
