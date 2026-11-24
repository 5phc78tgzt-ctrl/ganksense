import Testing
@testable import CompanionCore

@Test func parsesRunePageSpellsAndCounters() throws {
    let (headers, root) = try OPGGParser.parse(ChampSelectAdviceFixtures.ahriAnalysis)
    let advice = try #require(OPGGClient.advice(from: root, headers: headers))
    let runes = try #require(advice.runes)
    #expect(runes.primaryStyleID == 8100 && runes.subStyleID == 8200)
    #expect(runes.perkIDs == [8112, 8139, 8140, 8106, 8210, 8226, 5005, 5008, 5001])
    #expect(runes.keystoneName == "Electrocute")
    #expect(runes.shardNames == ["Attack speed", "Adaptive force", "Health scaling"])
    // win is a count: 26320 of 52224.
    #expect(Int(runes.winRate * 100) == 50)
    #expect(advice.spellNames == ["Flash", "Ignite"])
    #expect(advice.skillMax == ["Q", "W", "E"])
    // best counter first; the 12 game sample is dropped.
    #expect(advice.counters.map(\.championKey) == [950, 1, 105])
}

@Test func matchupVerdictFollowsLaneAdvantage() throws {
    let tip = try #require(OPGGClient.matchupTip(fromJSON: ChampSelectAdviceFixtures.zedMatchup, mine: "Ahri", opponent: "Zed"))
    #expect(tip.verdict == .unfavored)
    #expect(tip.tip == "Do not use Charm [E] until Zed closes in.")
    let mine = try #require(OPGGClient.matchupTip(fromJSON: ChampSelectAdviceFixtures.zedMatchup, mine: "Zed", opponent: "Ahri"))
    #expect(mine.verdict == .favored)
    // no advantage field (mirror, thin data): nothing to show.
    #expect(OPGGClient.matchupTip(fromJSON: ChampSelectAdviceFixtures.mirrorMatchup, mine: "Ahri", opponent: "Ahri") == nil)
}

private func page(primary: [Int] = [8112, 8139, 8140, 8106], secondary: [Int] = [8210, 8226],
                  shards: [Int] = [5005, 5008, 5001], style: Int = 8100, sub: Int = 8200) -> RunePage {
    RunePage(primaryStyleID: style, subStyleID: sub, primaryIDs: primary, secondaryIDs: secondary, shardIDs: shards)
}

@Test func runePageValidationRejectsMalformedPages() {
    #expect(page().isValid)
    // shards may repeat; precision keystones live outside the 80xx range.
    #expect(page(primary: [9111, 9104, 9105, 8299], shards: [5008, 5008, 5001], style: 8000).isValid)
    #expect(!page(primary: [8112, 8139, 8140]).isValid)
    #expect(!page(secondary: [8210, 8210]).isValid)
    #expect(!page(shards: [5005, 5008]).isValid)
    #expect(!page(shards: [5005, 5008, 9999]).isValid)
    #expect(!page(sub: 8100).isValid)
    #expect(!page(style: 1234).isValid)
    #expect(RunePageApplier.payload(for: page(secondary: [8210])) == nil)
}

@Test func payloadSelectsOurOwnPageWithAllNineIDs() throws {
    let payload = try #require(RunePageApplier.payload(for: page()))
    #expect(payload.name == "ganksense" && payload.current)
    #expect(payload.primaryStyleId == 8100 && payload.subStyleId == 8200)
    #expect(payload.selectedPerkIds == [8112, 8139, 8140, 8106, 8210, 8226, 5005, 5008, 5001])
}

@Test func applyPlanNeverTouchesForeignPagesAndRespectsSlots() {
    let mine = PerkPage(id: 7, name: "ganksense", isEditable: true, isDeletable: true)
    let foreign = PerkPage(id: 1, name: "my page", isEditable: true, isDeletable: true)
    let preset = PerkPage(id: 2, name: "Recommended", isEditable: false, isDeletable: false)
    let locked = PerkPage(id: 3, name: "ganksense", isEditable: false, isDeletable: false)

    #expect(RunePageApplier.plan(pages: [foreign, mine], ownedPageCount: 2) == .update(id: 7))
    // presets use no owned slot: one owned page of two leaves a free one.
    #expect(RunePageApplier.plan(pages: [preset, foreign], ownedPageCount: 2) == .create)
    #expect(RunePageApplier.plan(pages: [foreign, foreign], ownedPageCount: 2) == .noFreeSlot)
    // a same-named page we cannot edit is not ours.
    #expect(RunePageApplier.plan(pages: [locked, foreign], ownedPageCount: 1) == .noFreeSlot)
    // unreadable inventory: never guess.
    #expect(RunePageApplier.plan(pages: [foreign], ownedPageCount: nil) == .noFreeSlot)
}
