import Foundation

/// picks the next item: base build (op.gg or class template) re-ranked against the enemy threat profile.
public struct CounterBuildEngine: Sendable {
    /// a new top item must score this much higher than the current suggestion to replace it.
    public static let hysteresisMargin = 0.15

    static let weights: [CounterCategory: Double] = [
        .antiHeal: 1.3, .armorPen: 1.0, .magicPen: 1.0, .armor: 0.7, .magicResist: 0.7, .tenacity: 0.6,
        .stasis: 0.6, .spellShield: 0.5, .antiCrit: 0.6, .antiShield: 0.6, .lifeline: 0.5,
    ]

    static let maxFinishedItems = 6
    static let finishedCostThreshold = 2200
    static let bootsMinGameTime = 300.0
    static let bootsBasePriority = 0.95

    static let uniqueCategories: Set<CounterCategory> = [.antiHeal, .lifeline]

    /// curated unique passives (patch 16.23 names); names not in the catalog are ignored.
    static let uniqueGroups: [String: [String]] = [
        "lastWhisper": ["Lord Dominik's Regards", "Mortal Reminder", "Serylda's Grudge"],
        "hydra": ["Ravenous Hydra", "Titanic Hydra", "Profane Hydra"],
        "spellblade": ["Trinity Force", "Lich Bane", "Iceborn Gauntlet", "Essence Reaver"],
        "annul": ["Banshee's Veil", "Edge of Night"],
        "blight": ["Void Staff", "Cryptbloom"],
        "manaflow": ["Manamune", "Archangel's Staff", "Winter's Approach"],
        "quicksilver": ["Mercurial Scimitar", "Quicksilver Sash"],
        "immolate": ["Sunfire Aegis", "Hollow Radiance"],
    ]

    enum DamageType { case physical, magic, none }

    struct Candidate {
        var item: DDItem
        var score: Double
        var basePriority: Double
        var answered: [(category: CounterCategory, value: Double)]
        var isBoots: Bool
        var bootsReasons: [String] = []
        var counterValue: Double { answered.reduce(0) { $0 + $1.value } }
    }

    struct Context {
        var me: Player
        var archetype: ChampionArchetype
        var damage: DamageType
        var base: BaseBuild
        var owned: [DDItem]
        var profile: ThreatProfile
        var need: [CounterCategory: Double]
        var gold: Double
        var gameTime: Double
        var enemies: [Player]
    }

    let catalog: ItemCatalog
    let champions: ChampionCatalog
    let classifier: ItemClassifier
    private let shopIDs: Set<Int>
    private let groupsByID: [Int: Set<String>]

    public init(catalog: ItemCatalog, champions: ChampionCatalog) {
        self.catalog = catalog
        self.champions = champions
        classifier = ItemClassifier(catalog: catalog)
        shopIDs = Set(catalog.shopItems.map(\.id))
        var groups: [Int: Set<String>] = [:]
        for (group, names) in Self.uniqueGroups {
            for name in names {
                for item in catalog.items.values where item.name == name { groups[item.id, default: []].insert(group) }
            }
        }
        groupsByID = groups
    }

    /// legendary (or tier-2 boots) as far as suggestions go. `dditem.iscompleted` misses some legendaries
    /// whose `depth` is 2 in data dragon (infinity edge in 16.23), so finished-ness also accepts
    /// "builds into nothing and costs ≥ 2,200".
    static func isFinished(_ item: DDItem) -> Bool {
        if item.tags.contains("Boots") { return item.depth >= 2 }
        if item.tags.contains("Consumable") || item.tags.contains("Trinket") { return false }
        return item.isCompleted || (item.into.isEmpty && item.goldTotal >= finishedCostThreshold)
    }

    public func suggest(snapshot: LiveGameSnapshot, base: BaseBuild?, previous: BuildSuggestion?) -> BuildSuggestion? {
        guard let ctx = context(snapshot: snapshot, base: base) else { return nil }
        let list = ranked(ctx)
        guard let top = list.first else { return nil }

        var chosen = top
        if let previous, previous.next.id != top.item.id,
           let kept = list.first(where: { $0.item.id == previous.next.id }) {
            let threshold = kept.score > 0 ? kept.score * (1 + Self.hysteresisMargin) : kept.score + Self.hysteresisMargin
            if top.score < threshold { chosen = kept }
        }

        let then = list.first { $0.item.id != chosen.item.id && !conflicts($0, chosen) }
        let cost = chosen.item.goldTotal
        let reasons = chips(for: chosen, profile: ctx.profile)
        return BuildSuggestion(
            next: ItemRef(chosen.item),
            reasons: reasons,
            then: then.map { ItemRef($0.item) },
            costRemaining: max(0, cost - Int(ctx.gold)),
            goldProgress: cost > 0 ? min(1, max(0, ctx.gold) / Double(cost)) : 1,
            isCounter: !reasons.isEmpty)
    }

    func context(snapshot: LiveGameSnapshot, base: BaseBuild?) -> Context? {
        guard snapshot.isReady, snapshot.hasLiveFeatures, let me = snapshot.me else { return nil }
        let gameTime = snapshot.gameData?.gameTime ?? 0
        let champ = champions.champion(id: me.championID) ?? champions.champion(displayName: me.championName)
            ?? DDChampion(id: me.championID, key: 0, name: me.championName)
        let role = me.position.flatMap { Role(livePosition: $0) } ?? .mid
        let build = resolvedBase(base, champion: champ, role: role)
        let archetype = ChampionArchetype(champion: champ)
        let damage = damageType(of: build, champion: champ, archetype: archetype)

        let enemies = snapshot.enemies
        let profile = ThreatProfile.analyze(enemies: enemies, catalog: catalog, champions: champions,
                                            gameTime: gameTime, classifier: classifier)
        return Context(me: me, archetype: archetype, damage: damage, base: build,
                       owned: me.items.compactMap { catalog.item($0.itemID) }, profile: profile,
                       need: needs(profile, damage: damage, archetype: archetype),
                       gold: snapshot.activePlayer?.currentGold ?? 0, gameTime: gameTime, enemies: enemies)
    }

    /// the given base is used only while it still resolves to legal core items (op.gg drift / unknown ids).
    private func resolvedBase(_ base: BaseBuild?, champion: DDChampion, role: Role) -> BaseBuild {
        if let base, base.core.contains(where: { isLegalBaseItem($0) }) { return base }
        return ClassTemplates.baseBuild(for: champion, role: role, catalog: catalog, patch: catalog.version)
    }

    private func damageType(of build: BaseBuild, champion: DDChampion, archetype: ChampionArchetype) -> DamageType {
        var ad = 0.0, ap = 0.0
        for id in build.core where catalog.item(id) != nil {
            let d = classifier.damageProfile(id)
            ad += d.ad; ap += d.ap
        }
        if ad == 0 && ap == 0 {
            switch archetype {
            case .tank: return .none
            case .mage, .enchanter: return .magic
            default: return champion.magic > champion.attack ? .magic : .physical
            }
        }
        return ad >= ap ? .physical : .magic
    }

    func needs(_ p: ThreatProfile, damage: DamageType, archetype: ChampionArchetype) -> [CounterCategory: Double] {
        var n: [CounterCategory: Double] = [:]
        if p.healing >= 0.45 { n[.antiHeal] = p.healing }
        if damage == .physical, p.armorStack >= 1.1 { n[.armorPen] = min(1, p.armorStack / 1.6) }
        if damage == .magic, p.mrStack >= 1.1 { n[.magicPen] = min(1, p.mrStack / 1.6) }
        var armor = p.adShare >= 0.6 ? (p.adShare - 0.5) * 2 : 0
        if p.critCarry { armor = max(armor, 0.5) }
        if armor > 0 { n[.armor] = armor }
        if p.adShare <= 0.4 { n[.magicResist] = (0.5 - p.adShare) * 2 }
        if p.critCarry { n[.antiCrit] = 0.7 }
        if !p.burstAssassins.isEmpty, archetype == .mage || archetype == .marksman {
            let v = min(1, 0.5 + 0.15 * Double(p.burstAssassins.count - 1))
            n[.stasis] = v
            n[.lifeline] = v
            n[.spellShield] = v * 0.8
        }
        if p.heavyCC { n[.tenacity] = 0.7 }
        if p.shields >= 0.45 { n[.antiShield] = p.shields }
        return n
    }

    func ranked(snapshot: LiveGameSnapshot, base: BaseBuild?) -> [Candidate] {
        guard let ctx = context(snapshot: snapshot, base: base) else { return [] }
        return ranked(ctx)
    }

    func ranked(_ ctx: Context) -> [Candidate] {
        let finishedOwned = ctx.owned.filter { Self.isFinished($0) && !$0.tags.contains("Boots") }
        if finishedOwned.count >= Self.maxFinishedItems { return [] }

        let ownedIDs = Set(ctx.owned.map(\.id))
        let priority = basePriorities(ctx.base)
        var pool: [Int: Candidate] = [:]

        func consider(_ item: DDItem, basePriority: Double, fromBase: Bool) {
            guard let candidate = candidate(for: item, basePriority: basePriority, fromBase: fromBase,
                                            ctx: ctx, ownedIDs: ownedIDs) else { return }
            if let existing = pool[item.id], existing.score >= candidate.score { return }
            pool[item.id] = candidate
        }

        for (id, p) in priority {
            if let item = catalog.item(id) { consider(item, basePriority: p, fromBase: true) }
        }
        if !ctx.need.isEmpty {
            for id in shopIDs where priority[id] == nil {
                if let item = catalog.item(id) { consider(item, basePriority: 0, fromBase: false) }
            }
        }
        if let boots = bootsCandidate(ctx) { pool[boots.item.id] = boots }

        return pool.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.basePriority != $1.basePriority { return $0.basePriority > $1.basePriority }
            return $0.item.id < $1.item.id
        }
    }

    /// earlier base items weigh more; situational ones start lower and fade faster.
    private func basePriorities(_ base: BaseBuild) -> [Int: Double] {
        var priority: [Int: Double] = [:]
        for (i, id) in base.core.enumerated() {
            priority[id] = max(priority[id] ?? 0, max(0.5, 1.0 - 0.1 * Double(i)))
        }
        for (i, id) in base.situational.enumerated() {
            priority[id] = max(priority[id] ?? 0, max(0.2, 0.4 - 0.02 * Double(i)))
        }
        return priority
    }

    private func candidate(for item: DDItem, basePriority: Double, fromBase: Bool, ctx: Context,
                           ownedIDs: Set<Int>) -> Candidate? {
        guard shopIDs.contains(item.id), Self.isFinished(item), !item.tags.contains("Boots"),
              !ownedIDs.contains(item.id), !conflictsWithOwned(item, owned: ctx.owned) else { return nil }
        // base items are trusted (never dropped for class fit) but their counter value still scales with it.
        let itemFit = fromBase ? (opposesDamage(item, ctx.damage) ? 0 : max(0.5, fit(item, ctx))) : fit(item, ctx)
        guard itemFit > 0 else { return nil }

        let covered = coveredCategories(for: item, owned: ctx.owned)
        var answered: [(category: CounterCategory, value: Double)] = []
        var penalty = 0.0
        for category in classifier.categories(item.id) {
            guard let need = ctx.need[category], need > 0 else { continue }
            if covered.contains(category) { penalty = 0.5; continue }
            answered.append((category, need * (Self.weights[category] ?? 0.5) * itemFit))
        }
        answered.sort { $0.value != $1.value ? $0.value > $1.value : $0.category.rawValue < $1.category.rawValue }
        guard fromBase || !answered.isEmpty else { return nil }
        let score = basePriority + answered.reduce(0) { $0 + $1.value } - penalty
        return Candidate(item: item, score: score, basePriority: basePriority, answered: answered, isBoots: false)
    }

    private func isLegalBaseItem(_ id: Int) -> Bool {
        guard let item = catalog.item(id) else { return false }
        return shopIDs.contains(id) && Self.isFinished(item)
    }

    private func bootsCandidate(_ ctx: Context) -> Candidate? {
        guard ctx.gameTime >= Self.bootsMinGameTime else { return nil }
        if ctx.owned.contains(where: { $0.tags.contains("Boots") && $0.depth >= 2 }) { return nil }
        let p = ctx.profile
        let weight = { (category: CounterCategory) in (ctx.need[category] ?? 0) * (Self.weights[category] ?? 0) }
        var chosen: DDItem?
        var reasons: [String] = []
        var bonus = 0.0
        if p.adShare >= 0.65, autoAttackerCount(ctx.enemies) >= 2, let steelcaps = catalog.item(named: "Plated Steelcaps") {
            chosen = steelcaps
            reasons = p.reasons[.armor].map { Array($0.prefix(1)) } ?? []
            bonus = weight(.armor)
        } else if p.heavyCC || p.adShare <= 0.35, let mercs = catalog.item(named: "Mercury's Treads") {
            chosen = mercs
            reasons = (p.heavyCC ? p.reasons[.tenacity] : p.reasons[.magicResist]).map { Array($0.prefix(1)) } ?? []
            bonus = (p.heavyCC ? weight(.tenacity) : 0) + weight(.magicResist)
        } else if let id = ctx.base.boots, let b = catalog.item(id) {
            chosen = b
        }
        guard var boots = chosen, shopIDs.contains(boots.id), boots.depth >= 2 else { return nil }
        if opposesDamage(boots, ctx.damage), let fallback = ctx.base.boots.flatMap({ catalog.item($0) }) {
            boots = fallback
            reasons = []; bonus = 0
        }
        return Candidate(item: boots, score: Self.bootsBasePriority + bonus, basePriority: Self.bootsBasePriority,
                         answered: [], isBoots: true, bootsReasons: reasons)
    }

    private func autoAttackerCount(_ enemies: [Player]) -> Int {
        enemies.filter { enemy in
            let champ = champions.champion(id: enemy.championID) ?? champions.champion(displayName: enemy.championName)
            if champ?.tags.first == "Marksman" { return true }
            return enemy.items.contains { item in
                let stats = catalog.item(item.itemID)?.stats
                return (stats?["PercentAttackSpeedMod"] ?? 0) > 0 || (stats?["FlatCritChanceMod"] ?? 0) > 0
            }
        }.count
    }

    private func opposesDamage(_ item: DDItem, _ damage: DamageType) -> Bool {
        let d = classifier.damageProfile(item.id)
        guard d.ad + d.ap > 0 else { return false }
        switch damage {
        case .physical: return d.ap > d.ad
        case .magic: return d.ad > d.ap
        case .none: return false
        }
    }

    /// 0 = not for this champion; otherwise a multiplier on the counter value.
    func fit(_ item: DDItem, _ ctx: Context) -> Double {
        let d = classifier.damageProfile(item.id)
        let hasDamage = d.ad + d.ap > 0
        let isAD = hasDamage && d.ad >= d.ap
        let isAP = hasDamage && d.ap > d.ad
        let tags = Set(item.tags)
        let cats = classifier.categories(item.id)
        let isCrit = tags.contains("CriticalStrike")
        switch ctx.archetype {
        case .marksman:
            // crit / attack-speed items, or ad items whose point is staying alive (ga, maw, mercurial, shieldbow).
            guard isAD else { return 0 }
            if isCrit || tags.contains("AttackSpeed") { return 1 }
            return cats.isDisjoint(with: [.lifeline, .stasis, .tenacity, .magicResist]) ? 0 : 0.85
        case .assassinAD:
            guard isAD, !isCrit else { return 0 }
            if tags.contains("ArmorPenetration") { return 1 }
            return cats.isDisjoint(with: [.lifeline, .stasis, .spellShield, .magicResist]) ? 0.6 : 0.85
        case .fighter:
            if isAD { return isCrit ? 0 : 1 }
            return hasDamage ? 0 : 0.8
        case .mage:
            return isAP ? 1 : 0
        case .tank:
            return hasDamage ? 0 : 1
        case .enchanter:
            // supports rarely want damage items; utility items without damage stats are fine.
            if isAD { return 0 }
            return isAP ? 0.5 : (cats.isDisjoint(with: [.antiHeal]) ? 1 : 0)
        }
    }

    private func components(of item: DDItem) -> Set<Int> {
        var out: Set<Int> = []
        var stack = item.from
        while let id = stack.popLast() {
            guard out.insert(id).inserted, let c = catalog.item(id) else { continue }
            stack.append(contentsOf: c.from)
        }
        return out
    }

    /// categories already answered by owned items, not counting `item`'s own components (they get upgraded).
    private func coveredCategories(for item: DDItem, owned: [DDItem]) -> Set<CounterCategory> {
        let parts = components(of: item)
        var covered: Set<CounterCategory> = []
        for o in owned where !parts.contains(o.id) { covered.formUnion(classifier.categories(o.id)) }
        return covered
    }

    private func uniqueKeys(_ item: DDItem) -> Set<String> {
        var keys = groupsByID[item.id] ?? []
        for c in classifier.categories(item.id).intersection(Self.uniqueCategories) { keys.insert("cat:" + c.rawValue) }
        return keys
    }

    private func conflictsWithOwned(_ item: DDItem, owned: [DDItem]) -> Bool {
        let keys = uniqueKeys(item)
        guard !keys.isEmpty else { return false }
        let parts = components(of: item)
        return owned.contains { !parts.contains($0.id) && !uniqueKeys($0).isDisjoint(with: keys) }
    }

    private func conflicts(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.isBoots && b.isBoots { return true }
        return !uniqueKeys(a.item).isDisjoint(with: uniqueKeys(b.item))
    }

    func chips(for c: Candidate, profile: ThreatProfile) -> [String] {
        if c.isBoots { return c.bootsReasons }
        var out: [String] = []
        for (category, _) in c.answered {
            guard let labels = profile.reasons[category], let first = labels.first else { continue }
            var chip = first
            for suffix in [" healing", " shields"] where labels.count >= 2 && labels[0].hasSuffix(suffix)
                && labels[1].hasSuffix(suffix) {
                chip = String(labels[0].dropLast(suffix.count)) + " + " + labels[1]
            }
            if !out.contains(chip) { out.append(chip) }
            if out.count == 3 { break }
        }
        return out
    }
}
