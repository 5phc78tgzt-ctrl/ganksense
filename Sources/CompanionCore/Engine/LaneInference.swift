/// guesses which lane each enemy champion plays when the client does not say (the LCU reports enemy
/// positions in ranked only; normal draft leaves them empty). pure: a per-champion role preference list
/// (a short curated table for flex and off-meta picks, Data Dragon tags otherwise) and the best one-lane-each
/// assignment over the champions given.
public enum LaneInference {
    /// most likely lane first. only champions whose tags would mislead, or who are commonly flexed.
    static let curated: [String: [Role]] = [
        "Teemo": [.top, .jungle], "KSante": [.top], "Lillia": [.jungle, .top], "Seraphine": [.support, .adc, .mid],
        "Mel": [.mid, .support], "Orianna": [.mid], "Yone": [.mid, .top], "Yasuo": [.mid, .adc, .top],
        "Sylas": [.mid, .jungle, .top], "Pantheon": [.top, .support, .mid, .jungle], "Swain": [.support, .mid, .adc],
        "Brand": [.support, .jungle, .mid], "Zyra": [.support, .jungle], "Karma": [.support, .mid, .top],
        "Lux": [.support, .mid], "Neeko": [.mid, .support, .jungle], "Senna": [.support, .adc],
        "Ashe": [.adc, .support], "Sivir": [.adc], "Jayce": [.top, .mid], "Gragas": [.jungle, .top, .support],
        "Rumble": [.top, .mid, .jungle], "Vayne": [.adc, .top], "Kayle": [.top, .mid], "Quinn": [.top, .adc],
        "Tristana": [.adc, .mid], "Lucian": [.adc, .mid, .support], "Heimerdinger": [.top, .mid, .support],
        "Smolder": [.adc, .mid], "Naafiri": [.mid, .jungle], "Akali": [.mid, .top], "Aurora": [.mid, .top],
        "Zeri": [.adc], "Ambessa": [.top, .jungle], "Mordekaiser": [.top, .jungle],
    ]

    /// the roles a champion plays, most likely first.
    static func preferences(for champion: DDChampion) -> [Role] {
        if let known = curated[champion.id] { return known }
        let t = Set(champion.tags)
        var out: [Role] = []
        func add(_ roles: Role...) { for r in roles where !out.contains(r) { out.append(r) } }
        if t.contains("Marksman") { add(.adc) }
        if t.contains("Support") { add(.support) }
        if t.contains("Assassin") { add(.mid, .jungle) }
        if t.contains("Mage") { add(.mid, .support) }
        if t.contains("Fighter") { add(.top, .jungle) }
        if t.contains("Tank") { add(.top, .jungle, .support) }
        return out
    }

    /// the best assignment of distinct lanes to these champions, keyed by champion key. a champion's n-th
    /// preference scores more than its (n+1)-th; a lane beyond its list scores zero. ties keep the first
    /// assignment found. champions not in the catalog are ignored.
    public static func assign(championKeys: [Int], catalog: ChampionCatalog) -> [Int: Role] {
        let champs = championKeys.compactMap { catalog.champion(key: $0) }
        let prefs = champs.map(preferences(for:))
        var best: (score: Int, picks: [Role])?
        var current: [Role] = []

        func search(_ i: Int, _ score: Int) {
            if i == champs.count {
                if best == nil || score > best!.score { best = (score, current) }
                return
            }
            for role in Role.allCases where !current.contains(role) {
                let rank = prefs[i].firstIndex(of: role).map { 10 - $0 * 3 } ?? 0
                current.append(role)
                search(i + 1, score + rank)
                current.removeLast()
            }
        }
        search(0, 0)
        guard let picks = best?.picks else { return [:] }
        return Dictionary(zip(champs.map(\.key), picks), uniquingKeysWith: { a, _ in a })
    }
}
