import Foundation

/// champion-select advice from op.gg: rune page, spells, skill order, counters, and the lane matchup tip.
/// requests carry only champion, role, mode (and the opponent champion for the matchup).
public protocol ChampSelectAdviceSource: Sendable {
    func advice(championID: String, role: Role) async -> ChampionAdvice?
    func matchupTip(championID: String, championName: String, opponentID: String, opponentName: String,
                    role: Role) async -> MatchupTip?
}

extension OPGGClient: ChampSelectAdviceSource {
    static let adviceFields = [
        "data.runes.{primary_page_id,primary_page_name,primary_rune_ids[],primary_rune_names[],secondary_page_id,secondary_page_name,secondary_rune_ids[],secondary_rune_names[],stat_mod_ids[],play,win,pick_rate}",
        "data.summoner_spells.{ids[],ids_names[]}",
        "data.skill_masteries.{ids[]}",
        "data.weak_counters[].{champion_id,champion_name,win_rate,play}",
    ]

    public func advice(championID: String, role: Role) async -> ChampionAdvice? {
        let file = cacheFile(championID: championID, name: "\(role.rawValue)_advice")
        if let cached: ChampionAdvice = Self.readCache(file) { return cached }
        let arguments: [String: Any] = [
            "champion": Self.opggName(championID),
            "position": role.rawValue,
            "game_mode": "ranked",
            "desired_output_fields": Self.adviceFields,
        ]
        guard let text = await fetchText(tool: "lol_get_champion_analysis", arguments: arguments),
              let parsed = try? OPGGParser.parse(text),
              let advice = Self.advice(from: parsed.root, headers: parsed.headers)
        else { return nil }
        Self.writeCache(advice, to: file)
        return advice
    }

    public func matchupTip(championID: String, championName: String, opponentID: String, opponentName: String,
                           role: Role) async -> MatchupTip? {
        let file = cacheFile(championID: championID, name: "vs3_\(opponentID)_\(role.rawValue)")
        if let cached: MatchupTip = Self.readCache(file) { return cached }
        let arguments: [String: Any] = [
            "my_champion": Self.opggName(championID),
            "opponent_champion": Self.opggName(opponentID),
            "position": role.rawValue,
        ]
        guard let text = await fetchText(tool: "lol_get_lane_matchup_guide", arguments: arguments),
              let tip = Self.matchupTip(fromJSON: text, mine: championName, opponent: opponentName)
        else { return nil }
        Self.writeCache(tip, to: file)
        return tip
    }

    static let maxCounters = 8
    static let minCounterGames = 100
    static let maxTipLength = 220

    static let shardNames: [Int: String] = [
        5001: "Health scaling", 5002: "Armor", 5003: "Magic resist", 5005: "Attack speed",
        5007: "Ability haste", 5008: "Adaptive force", 5010: "Move speed", 5011: "Health", 5013: "Tenacity",
    ]

    static let spellNames: [Int: String] = [
        1: "Cleanse", 3: "Exhaust", 4: "Flash", 6: "Ghost", 7: "Heal", 11: "Smite", 12: "Teleport",
        14: "Ignite", 21: "Barrier", 32: "Mark",
    ]

    /// maps the champion analysis tree by header field name (the field order differs per class).
    /// nil when it carries neither a valid rune page nor any counter.
    static func advice(from root: OPGGValue, headers: [String: [String]]) -> ChampionAdvice? {
        guard let rootRecord = Record(root, headers),
              let data = rootRecord["data"].flatMap({ Record($0, headers) }) else { return nil }

        var runes: RunePage?
        if let r = data["runes"].flatMap({ Record(firstOf($0), headers) }) {
            let primaryIDs = r["primary_rune_ids"].flatMap(ints) ?? []
            let secondaryIDs = r["secondary_rune_ids"].flatMap(ints) ?? []
            let shardIDs = r["stat_mod_ids"].flatMap(ints) ?? []
            let page = RunePage(
                primaryStyleID: r["primary_page_id"].flatMap(int) ?? 0,
                subStyleID: r["secondary_page_id"].flatMap(int) ?? 0,
                primaryStyleName: r["primary_page_name"].flatMap(string) ?? "",
                subStyleName: r["secondary_page_name"].flatMap(string) ?? "",
                primaryIDs: primaryIDs,
                primaryNames: r["primary_rune_names"].flatMap(strings) ?? [],
                secondaryIDs: secondaryIDs,
                secondaryNames: r["secondary_rune_names"].flatMap(strings) ?? [],
                shardIDs: shardIDs,
                shardNames: shardIDs.map { shardNames[$0] ?? "" },
                play: r["play"].flatMap(int) ?? 0, win: r["win"].flatMap(int) ?? 0,
                pickRate: r["pick_rate"].flatMap(number) ?? 0)
            // names must line up with ids, or the popover would show the wrong rune.
            if page.isValid, page.primaryNames.count == 4, page.secondaryNames.count == 2 { runes = page }
        }

        var spells: [String] = []
        if let s = data["summoner_spells"].flatMap({ Record(firstOf($0), headers) }), let ids = s["ids"].flatMap(ints) {
            spells = ids.compactMap { spellNames[$0] }
            if spells.count != ids.count { spells = s["ids_names"].flatMap(strings) ?? [] }
        }

        var skills: [String] = []
        if let m = data["skill_masteries"].flatMap({ Record(firstOf($0), headers) }),
           let ids = m["ids"].flatMap(strings), ids.allSatisfy({ ["Q", "W", "E"].contains($0) }) {
            skills = ids
        }

        var counters: [CounterPick] = []
        if let value = data["weak_counters"], case let .array(rows) = value {
            for row in rows {
                guard let c = Record(row, headers),
                      let key = c["champion_id"].flatMap(int), key > 0,
                      let name = c["champion_name"].flatMap(string), !name.isEmpty,
                      let rate = c["win_rate"].flatMap(number), rate.isFinite, rate > 0, rate < 1,
                      let play = c["play"].flatMap(int), play >= minCounterGames else { continue }
                counters.append(CounterPick(championKey: key, name: name, winRate: rate, play: play))
            }
            counters.sort { ($1.winRate, $0.championKey) < ($0.winRate, $1.championKey) }
            counters = Array(counters.prefix(maxCounters))
        }

        guard runes != nil || !counters.isEmpty else { return nil }
        return ChampionAdvice(runes: runes, spellNames: spells, skillMax: skills, counters: counters)
    }

    /// the lane matchup guide is plain json, not the op.gg dsl. `lane_advantage_champion` names the favored
    /// champion (display name), "EVEN", or is null (mirror matchups, thin data): then there is no verdict.
    static func matchupTip(fromJSON text: String, mine: String, opponent: String) -> MatchupTip? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let edge = data["lane_advantage_champion"] as? String else { return nil }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let verdict: MatchupTip.Verdict
        if norm(edge) == "even" {
            verdict = .even
        } else if norm(edge) == norm(opponent) {
            verdict = .unfavored
        } else if norm(edge) == norm(mine) {
            verdict = .favored
        } else {
            return nil
        }
        var tip = (data["opponent_champion_tip"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = tip {
            if t.isEmpty {
                tip = nil
            } else if t.count > maxTipLength {
                tip = String(t.prefix(maxTipLength)).trimmingCharacters(in: .whitespaces) + "…"
            }
        }
        return MatchupTip(verdict: verdict, opponent: opponent, tip: tip, runes: matchupRunes(data),
                          coreItems: matchupCore(data).names, coreItemIDs: matchupCore(data).ids)
    }

    /// the first (most played) matchup rune page, when valid and played often enough.
    static func matchupRunes(_ data: [String: Any]) -> RunePage? {
        guard let r = (data["runes"] as? [[String: Any]])?.first else { return nil }
        func ids(_ key: String) -> [Int] { (r[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
        func names(_ key: String) -> [String] { (r[key] as? [String]) ?? [] }
        let shards = ids("stat_mod_ids")
        let page = RunePage(
            primaryStyleID: (r["primary_page_id"] as? Int) ?? 0, subStyleID: (r["secondary_page_id"] as? Int) ?? 0,
            primaryStyleName: (r["primary_page_name"] as? String) ?? "", subStyleName: (r["secondary_page_name"] as? String) ?? "",
            primaryIDs: ids("primary_rune_ids"), primaryNames: names("primary_rune_names"),
            secondaryIDs: ids("secondary_rune_ids"), secondaryNames: names("secondary_rune_names"),
            shardIDs: shards, shardNames: shards.map { shardNames[$0] ?? "" },
            play: (r["play"] as? Int) ?? 0, win: (r["win"] as? Int) ?? 0, pickRate: (r["pick_rate"] as? Double) ?? 0)
        guard page.isValid, page.primaryNames.count == 4, page.secondaryNames.count == 2,
              page.play >= MatchupTip.minRuneGames else { return nil }
        return page
    }

    static func matchupCore(_ data: [String: Any]) -> (names: [String], ids: [Int]) {
        let first = (data["core_items"] as? [[String: Any]])?.first
        let names = (first?["ids_names"] as? [String]) ?? []
        let ids = (first?["ids"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        return names.count == 3 && ids.count == 3 ? (names, ids) : ([], [])
    }

    // MARK: tree helpers

    /// a constructor call whose arguments are read by header field name.
    struct Record {
        let fields: [String]
        let args: [OPGGValue]

        init?(_ value: OPGGValue, _ headers: [String: [String]]) {
            guard case let .object(name, args) = value, let fields = headers[name] else { return nil }
            self.fields = fields
            self.args = args
        }

        subscript(key: String) -> OPGGValue? {
            guard let i = fields.firstIndex(of: key), i < args.count else { return nil }
            return args[i]
        }
    }

    /// a field that may arrive as one object or as a list of options: the first one.
    static func firstOf(_ value: OPGGValue) -> OPGGValue {
        if case let .array(items) = value, let first = items.first { return first }
        return value
    }

    static func number(_ value: OPGGValue) -> Double? {
        if case let .number(d) = value, d.isFinite { return d }
        return nil
    }

    static func int(_ value: OPGGValue) -> Int? {
        guard let d = number(value), d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func string(_ value: OPGGValue) -> String? {
        if case let .string(s) = value { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    static func ints(_ value: OPGGValue) -> [Int]? {
        guard case let .array(items) = value else { return nil }
        let out = items.compactMap(int)
        return out.count == items.count ? out : nil
    }

    static func strings(_ value: OPGGValue) -> [String]? {
        guard case let .array(items) = value else { return nil }
        let out = items.compactMap(string)
        return out.count == items.count ? out : nil
    }
}
