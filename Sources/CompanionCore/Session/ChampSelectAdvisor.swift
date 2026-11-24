import Foundation
import Observation

/// champion-select advice state: rune page, spells, skill order and ban ideas for my champion and role, plus the
/// lane matchup tip (which stays through the game). everything is fetched from op.gg once per (champion, role)
/// or matchup; polls that change nothing only compare keys. nothing needs a role-less mode: blind pick, aram
/// and arena get no advice.
@MainActor @Observable
public final class ChampSelectAdvisor {
    struct Env {
        var source: ChampSelectAdviceSource?
        var catalog: ChampionCatalog?
        var enabled: Bool
        var sleep: @Sendable (Duration) async throws -> Void
    }

    public private(set) var advice: ChampionAdvice?
    /// display name of the champion `advice` belongs to.
    public private(set) var adviceChampion: String?
    public private(set) var role: Role?
    public private(set) var matchup: MatchupTip?
    /// banned or locked champions, filtered out of the ban ideas.
    public private(set) var unavailable: Set<Int> = []
    /// data dragon id and display name of the champion I hold now (hover or lock), before any advice arrives.
    public private(set) var myChampionID: String?
    /// display name of my lane opponent once revealed.
    public private(set) var enemyName: String?
    /// the opponent is a guess from their champion (the client gave no enemy positions).
    public private(set) var enemyInferred = false
    /// data dragon id of that opponent, for the portrait.
    public private(set) var enemyID: String?
    /// team check warnings, once four of five picks are known.
    public private(set) var teamWarnings: [String] = []

    /// up to five champions that beat mine in my role and can still be banned.
    public var banIdeas: [CounterPick] {
        guard let counters = advice?.counters else { return [] }
        return Array(counters.filter { !unavailable.contains($0.championKey) }.prefix(Self.maxBanIdeas))
    }

    static let maxBanIdeas = 5
    /// fewer locked enemies than this make a lane guess too unstable.
    static let minInferredPicks = 4
    private static let debounce: Duration = .milliseconds(500)

    /// fixed preview data: polls must not clear it.
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var adviceKey: String?
    @ObservationIgnored private var matchupKey: String?
    @ObservationIgnored private var adviceTask: Task<Void, Never>?
    @ObservationIgnored private var matchupTask: Task<Void, Never>?

    public init() {}

    /// one champ select poll. idempotent: nothing is fetched unless my champion/role or the lane pair changed.
    func champSelect(_ info: ChampSelectInfo, env: Env) {
        guard !previewing else { return }
        guard env.enabled, info.isDraft, let role = info.role, let source = env.source, let catalog = env.catalog else {
            reset()
            return
        }
        if unavailable != info.unavailable { unavailable = info.unavailable }
        guard let mine = info.championKey.flatMap({ catalog.champion(key: $0) }) else {
            if myChampionID != nil { myChampionID = nil }
            if teamWarnings != [] { teamWarnings = [] }
            clearAdvice()
            clearMatchup()
            return
        }

        if myChampionID != mine.id { myChampionID = mine.id }
        let warnings = TeamComp.warnings(mine: mine, allies: info.allies.compactMap { catalog.champion(key: $0) })
        if teamWarnings != warnings { teamWarnings = warnings }

        let key = "\(mine.id)|\(role.rawValue)"
        if key != adviceKey {
            clearAdvice()
            adviceKey = key
            self.role = role
            let sleep = env.sleep
            adviceTask = Task { [weak self] in
                // hovering through champions would otherwise fetch each one.
                try? await sleep(Self.debounce)
                guard !Task.isCancelled else { return }
                let result = await source.advice(championID: mine.id, role: role)
                guard !Task.isCancelled, let self, self.adviceKey == key else { return }
                self.advice = result
                self.adviceChampion = mine.name
            }
        }

        var enemyKey = info.enemyLaner
        var inferred = false
        if enemyKey == nil, info.enemyPicks.count >= Self.minInferredPicks {
            enemyKey = LaneInference.assign(championKeys: info.enemyPicks, catalog: catalog)
                .first { $0.value == role }?.key
            inferred = enemyKey != nil
        }
        if enemyInferred != inferred { enemyInferred = inferred }
        guard let enemy = enemyKey.flatMap({ catalog.champion(key: $0) }) else {
            // the lane opponent is not revealed (or my pick changed): no tip.
            if enemyName != nil { enemyName = nil; enemyID = nil }
            clearMatchup()
            return
        }
        if enemyName != enemy.name { enemyName = enemy.name; enemyID = enemy.id }
        fetchMatchup(mine: mine, enemy: enemy, role: role, source: source)
    }

    /// in game: the opponent in my live position, once per game. champ select may have fetched it already.
    func inGame(_ snapshot: LiveGameSnapshot, env: Env) {
        guard !previewing, matchupKey == nil, env.enabled, snapshot.isSummonersRift, let source = env.source,
              let catalog = env.catalog, let me = snapshot.me,
              let role = me.position.flatMap({ Role(livePosition: $0) }),
              let mine = Self.champion(of: me, in: catalog),
              let enemy = snapshot.enemies.first(where: { $0.position.flatMap { Role(livePosition: $0) } == role })
                .flatMap({ Self.champion(of: $0, in: catalog) })
        else { return }
        fetchMatchup(mine: mine, enemy: enemy, role: role, source: source)
    }

    /// champ select is over. a dodge back to the lobby clears everything; a game start keeps the matchup tip.
    func leftChampSelect(keepMatchup: Bool) {
        guard !previewing else { return }
        if keepMatchup {
            clearAdvice()
            unavailable = []
        } else {
            reset()
        }
    }

    func reset() {
        guard !previewing else { return }
        if myChampionID != nil { myChampionID = nil }
        if enemyName != nil { enemyName = nil; enemyID = nil }
        if enemyInferred { enemyInferred = false }
        if !teamWarnings.isEmpty { teamWarnings = [] }
        clearAdvice()
        clearMatchup()
        if !unavailable.isEmpty { unavailable = [] }
    }

    /// ends `showpreview`: back to live champ select data.
    public func endPreview() {
        previewing = false
        reset()
    }

    /// debug (--popover-preview champselect): shows fixed advice without any network.
    public func showPreview(advice: ChampionAdvice, champion: String, role: Role, matchup: MatchupTip?,
                            championID: String? = nil, warnings: [String] = []) {
        previewing = true
        myChampionID = championID
        enemyName = matchup?.opponent
        enemyID = matchup?.opponent
        teamWarnings = warnings
        self.advice = advice
        adviceChampion = champion
        self.role = role
        self.matchup = matchup
    }

    private static func champion(of player: Player, in catalog: ChampionCatalog) -> DDChampion? {
        catalog.champion(id: player.championID) ?? catalog.champion(displayName: player.championName)
    }

    private func fetchMatchup(mine: DDChampion, enemy: DDChampion, role: Role, source: ChampSelectAdviceSource) {
        let key = "\(mine.id)|\(enemy.id)|\(role.rawValue)"
        guard key != matchupKey else { return }
        clearMatchup()
        matchupKey = key
        matchupTask = Task { [weak self] in
            let result = await source.matchupTip(championID: mine.id, championName: mine.name, opponentID: enemy.id,
                                                 opponentName: enemy.name, role: role)
            guard !Task.isCancelled, let self, self.matchupKey == key else { return }
            self.matchup = result
        }
    }

    private func clearAdvice() {
        adviceTask?.cancel()
        adviceTask = nil
        adviceKey = nil
        if advice != nil { advice = nil }
        if adviceChampion != nil { adviceChampion = nil }
    }

    private func clearMatchup() {
        matchupTask?.cancel()
        matchupTask = nil
        matchupKey = nil
        if matchup != nil { matchup = nil }
    }
}
