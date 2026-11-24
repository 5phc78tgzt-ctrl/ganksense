import Testing
@testable import CompanionCore

@Suite struct GamePatternsTests {
    @Test func belowThreeGamesWithAResultIsNil() {
        let records = [patternGame(1), patternGame(2), patternGame(3, win: nil), patternGame(4, void: true)]
        #expect(GamePatterns.compute(records: records) == nil)
        #expect(GamePatterns.compute(records: []) == nil)
        #expect(GamePatterns.compute(records: records + [patternGame(5)]) != nil)
    }

    @Test func countsEarlyDeathsGoalsAndRepeatedKiller() throws {
        let early = [(300.0, "Zed"), (600.0, "Zed")]
        var records = (1...3).map { patternGame($0, deaths: early, goal: $0 == 1 ? .failed : $0 == 2 ? .close : .achieved) }
        records.append(patternGame(4, deaths: [(1200, "Zed")]))
        let p = try #require(GamePatterns.compute(records: records))
        #expect(p.games == 4)
        #expect(p.earlyDeathsPerGame == 1.5)
        #expect(p.goals == GamePatterns.GoalRecord(met: 1, nearMiss: 1, missed: 1))
        #expect(p.topKiller?.champion == "Zed" && p.topKiller?.count == 7)
        #expect(p.trend == nil)
        #expect(p.suggestion?.preset == .deathsBefore14)
    }

    @Test func trendComparesNewestFiveWithThePreviousFive() throws {
        let older = (1...5).map { patternGame($0, deaths: [(200, "A"), (300, "B"), (400, "C")]) }
        let newer = (6...10).map { patternGame($0, deaths: [(500, "A")]) }
        let p = try #require(GamePatterns.compute(records: older + newer))
        #expect(p.trend?.recent == 1 && p.trend?.previous == 3 && p.trend?.direction == .improving)
        let few = try #require(GamePatterns.compute(records: Array((older + newer).suffix(7))))
        #expect(few.trend == nil)
    }

    @Test func onlyTheLastTenGamesCount() throws {
        let old = patternGame(1, deaths: [(100, "A"), (200, "A"), (300, "A")])
        let recent = (2...11).map { patternGame($0) }
        let p = try #require(GamePatterns.compute(records: [old] + recent))
        #expect(p.games == 10 && p.deaths == 0 && p.topCause == nil && p.reviewLine == nil)
    }
}
