import Foundation

extension KeyedDecodingContainer {
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// decodes an element without ever failing, so one bad entry cannot drop a whole array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public enum Team: Sendable, Equatable, Hashable, Decodable {
    case order, chaos, unknown

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        switch raw.uppercased() {
        case "ORDER": self = .order
        case "CHAOS": self = .chaos
        default: self = .unknown
        }
    }
}

public struct RuneRef: Decodable, Sendable, Equatable {
    public var id: Int?
    public var displayName: String?

    public init(id: Int? = nil, displayName: String? = nil) {
        self.id = id; self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey { case id, displayName }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(Int.self, .id)
        displayName = c.lenient(String.self, .displayName)
    }
}

public struct Runes: Decodable, Sendable, Equatable {
    public var keystone: RuneRef?
    public var primaryRuneTree: RuneRef?
    public var secondaryRuneTree: RuneRef?

    public init(keystone: RuneRef? = nil, primaryRuneTree: RuneRef? = nil, secondaryRuneTree: RuneRef? = nil) {
        self.keystone = keystone; self.primaryRuneTree = primaryRuneTree; self.secondaryRuneTree = secondaryRuneTree
    }

    enum CodingKeys: String, CodingKey { case keystone, primaryRuneTree, secondaryRuneTree }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keystone = c.lenient(RuneRef.self, .keystone)
        primaryRuneTree = c.lenient(RuneRef.self, .primaryRuneTree)
        secondaryRuneTree = c.lenient(RuneRef.self, .secondaryRuneTree)
    }
}

public struct ChampionStats: Decodable, Sendable, Equatable {
    public var abilityPower: Double?
    public var armor: Double?
    public var attackDamage: Double?
    public var magicResist: Double?
    public var maxHealth: Double?
    public var currentHealth: Double?

    public init(abilityPower: Double? = nil, armor: Double? = nil, attackDamage: Double? = nil,
                magicResist: Double? = nil, maxHealth: Double? = nil, currentHealth: Double? = nil) {
        self.abilityPower = abilityPower; self.armor = armor; self.attackDamage = attackDamage
        self.magicResist = magicResist; self.maxHealth = maxHealth; self.currentHealth = currentHealth
    }

    enum CodingKeys: String, CodingKey { case abilityPower, armor, attackDamage, magicResist, maxHealth, currentHealth }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        abilityPower = c.lenient(Double.self, .abilityPower)
        armor = c.lenient(Double.self, .armor)
        attackDamage = c.lenient(Double.self, .attackDamage)
        magicResist = c.lenient(Double.self, .magicResist)
        maxHealth = c.lenient(Double.self, .maxHealth)
        currentHealth = c.lenient(Double.self, .currentHealth)
    }
}

public struct PlayerItem: Decodable, Sendable, Equatable {
    public var itemID: Int
    public var displayName: String?
    public var count: Int
    public var slot: Int
    public var price: Int?

    public init(itemID: Int, displayName: String? = nil, count: Int = 1, slot: Int = 0, price: Int? = nil) {
        self.itemID = itemID; self.displayName = displayName; self.count = count; self.slot = slot; self.price = price
    }

    enum CodingKeys: String, CodingKey { case itemID, displayName, count, slot, price }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = c.lenient(Int.self, .itemID) ?? 0
        displayName = c.lenient(String.self, .displayName)
        count = c.lenient(Int.self, .count) ?? 1
        slot = c.lenient(Int.self, .slot) ?? 0
        price = c.lenient(Int.self, .price)
    }
}

public struct Scores: Decodable, Sendable, Equatable {
    public var kills: Int
    public var deaths: Int
    public var assists: Int
    public var creepScore: Int
    public var wardScore: Double

    public init(kills: Int = 0, deaths: Int = 0, assists: Int = 0, creepScore: Int = 0, wardScore: Double = 0) {
        self.kills = kills; self.deaths = deaths; self.assists = assists
        self.creepScore = creepScore; self.wardScore = wardScore
    }

    enum CodingKeys: String, CodingKey { case kills, deaths, assists, creepScore, wardScore }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kills = c.lenient(Int.self, .kills) ?? 0
        deaths = c.lenient(Int.self, .deaths) ?? 0
        assists = c.lenient(Int.self, .assists) ?? 0
        creepScore = c.lenient(Int.self, .creepScore) ?? 0
        wardScore = c.lenient(Double.self, .wardScore) ?? 0
    }
}

public struct Player: Decodable, Sendable, Equatable {
    public var championName: String
    public var rawChampionName: String?
    public var team: Team
    public var level: Int
    public var items: [PlayerItem]
    public var runes: Runes?
    public var scores: Scores
    public var summonerName: String?
    public var riotId: String?
    public var riotIdGameName: String?
    public var riotIdTagLine: String?
    public var isDead: Bool
    public var respawnTimer: Double
    public var position: String?
    public var summonerSpellNames: [String]

    public init(championName: String, rawChampionName: String? = nil, team: Team = .unknown, level: Int = 0,
                items: [PlayerItem] = [], runes: Runes? = nil, scores: Scores = Scores(),
                summonerName: String? = nil, riotId: String? = nil, riotIdGameName: String? = nil,
                riotIdTagLine: String? = nil, isDead: Bool = false, respawnTimer: Double = 0,
                position: String? = nil, summonerSpellNames: [String] = []) {
        self.championName = championName; self.rawChampionName = rawChampionName; self.team = team
        self.level = level; self.items = items; self.runes = runes; self.scores = scores
        self.summonerName = summonerName; self.riotId = riotId; self.riotIdGameName = riotIdGameName
        self.riotIdTagLine = riotIdTagLine; self.isDead = isDead; self.respawnTimer = respawnTimer
        self.position = position; self.summonerSpellNames = summonerSpellNames
    }

    enum CodingKeys: String, CodingKey {
        case championName, rawChampionName, team, level, items, runes, scores
        case summonerName, riotId, riotIdGameName, riotIdTagLine, isDead, respawnTimer, position, summonerSpells
    }

    private struct Spell: Decodable {
        var displayName: String?
        init(from decoder: Decoder) throws {
            displayName = try? decoder.container(keyedBy: Keys.self).lenient(String.self, .displayName)
        }
        enum Keys: String, CodingKey { case displayName }
    }
    private struct Spells: Decodable {
        var names: [String]
        enum Keys: String, CodingKey { case summonerSpellOne, summonerSpellTwo }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            names = [c.lenient(Spell.self, .summonerSpellOne), c.lenient(Spell.self, .summonerSpellTwo)]
                .compactMap { $0?.displayName }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        championName = c.lenient(String.self, .championName) ?? ""
        rawChampionName = c.lenient(String.self, .rawChampionName)
        team = c.lenient(Team.self, .team) ?? .unknown
        level = c.lenient(Int.self, .level) ?? 0
        items = (c.lenient([Lossy<PlayerItem>].self, .items) ?? []).compactMap(\.value)
        runes = c.lenient(Runes.self, .runes)
        scores = c.lenient(Scores.self, .scores) ?? Scores()
        summonerName = c.lenient(String.self, .summonerName)
        riotId = c.lenient(String.self, .riotId)
        riotIdGameName = c.lenient(String.self, .riotIdGameName)
        riotIdTagLine = c.lenient(String.self, .riotIdTagLine)
        isDead = c.lenient(Bool.self, .isDead) ?? false
        respawnTimer = c.lenient(Double.self, .respawnTimer) ?? 0
        position = c.lenient(String.self, .position)
        summonerSpellNames = c.lenient(Spells.self, .summonerSpells)?.names ?? []
    }

    /// data dragon style champion id: from `rawchampionname` if it has the riot prefix, else the display name
    /// with spaces and punctuation removed.
    public var championID: String {
        let prefix = "game_character_displayname_"
        if let raw = rawChampionName, raw.hasPrefix(prefix), raw.count > prefix.count {
            return String(raw.dropFirst(prefix.count))
        }
        return String(championName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    fileprivate var identifiers: [String] {
        playerIdentifiers(riotId: riotId, summonerName: summonerName, gameName: riotIdGameName,
                          tagLine: riotIdTagLine)
    }

    public func isSameAs(_ name: String?) -> Bool {
        identifiers.contains { namesMatch($0, name) }
    }
}

public struct ActivePlayer: Decodable, Sendable, Equatable {
    public var summonerName: String?
    public var riotId: String?
    public var riotIdGameName: String?
    public var riotIdTagLine: String?
    public var level: Int?
    public var currentGold: Double?
    public var championStats: ChampionStats?
    public var fullRunes: Runes?

    public init(summonerName: String? = nil, riotId: String? = nil, riotIdGameName: String? = nil,
                riotIdTagLine: String? = nil, level: Int? = nil, currentGold: Double? = nil,
                championStats: ChampionStats? = nil, fullRunes: Runes? = nil) {
        self.summonerName = summonerName; self.riotId = riotId; self.riotIdGameName = riotIdGameName
        self.riotIdTagLine = riotIdTagLine; self.level = level; self.currentGold = currentGold
        self.championStats = championStats; self.fullRunes = fullRunes
    }

    enum CodingKeys: String, CodingKey {
        case summonerName, riotId, riotIdGameName, riotIdTagLine, level, currentGold, championStats, fullRunes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summonerName = c.lenient(String.self, .summonerName)
        riotId = c.lenient(String.self, .riotId)
        riotIdGameName = c.lenient(String.self, .riotIdGameName)
        riotIdTagLine = c.lenient(String.self, .riotIdTagLine)
        level = c.lenient(Int.self, .level)
        currentGold = c.lenient(Double.self, .currentGold)
        championStats = c.lenient(ChampionStats.self, .championStats)
        fullRunes = c.lenient(Runes.self, .fullRunes)
    }

    fileprivate var identifiers: [String] {
        playerIdentifiers(riotId: riotId, summonerName: summonerName, gameName: riotIdGameName,
                          tagLine: riotIdTagLine)
    }
}

public struct GameEvent: Decodable, Sendable, Equatable {
    public var id: Int
    public var name: String
    public var time: Double
    public var killer: String?
    public var victim: String?
    public var assisters: [String]
    public var result: String?

    public init(id: Int, name: String, time: Double, killer: String? = nil, victim: String? = nil,
                assisters: [String] = [], result: String? = nil) {
        self.id = id; self.name = name; self.time = time; self.killer = killer
        self.victim = victim; self.assisters = assisters; self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case id = "EventID", name = "EventName", time = "EventTime"
        case killer = "KillerName", victim = "VictimName", assisters = "Assisters", result = "Result"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(Int.self, .id) ?? 0
        name = c.lenient(String.self, .name) ?? ""
        time = c.lenient(Double.self, .time) ?? 0
        killer = c.lenient(String.self, .killer)
        victim = c.lenient(String.self, .victim)
        assisters = c.lenient([String].self, .assisters) ?? []
        result = c.lenient(String.self, .result)
    }
}

public struct GameData: Decodable, Sendable, Equatable {
    public var gameMode: String
    public var gameTime: Double
    public var mapNumber: Int

    public init(gameMode: String = "", gameTime: Double = 0, mapNumber: Int = 0) {
        self.gameMode = gameMode; self.gameTime = gameTime; self.mapNumber = mapNumber
    }

    enum CodingKeys: String, CodingKey { case gameMode, gameTime, mapNumber }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameMode = c.lenient(String.self, .gameMode) ?? ""
        gameTime = c.lenient(Double.self, .gameTime) ?? 0
        mapNumber = c.lenient(Int.self, .mapNumber) ?? 0
    }
}

public struct LiveGameSnapshot: Decodable, Sendable, Equatable {
    public var activePlayer: ActivePlayer?
    public var allPlayers: [Player]
    public var events: [GameEvent]
    public var gameData: GameData?

    public init(activePlayer: ActivePlayer? = nil, allPlayers: [Player] = [], events: [GameEvent] = [],
                gameData: GameData? = nil) {
        self.activePlayer = activePlayer; self.allPlayers = allPlayers
        self.events = events; self.gameData = gameData
    }

    enum CodingKeys: String, CodingKey { case activePlayer, allPlayers, events, gameData }
    private struct EventsWrapper: Decodable {
        var events: [GameEvent]
        enum CodingKeys: String, CodingKey { case events = "Events" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            events = (c.lenient([Lossy<GameEvent>].self, .events) ?? []).compactMap(\.value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activePlayer = c.lenient(ActivePlayer.self, .activePlayer)
        allPlayers = (c.lenient([Lossy<Player>].self, .allPlayers) ?? []).compactMap(\.value)
        events = c.lenient(EventsWrapper.self, .events)?.events ?? []
        gameData = c.lenient(GameData.self, .gameData)
    }
}

extension LiveGameSnapshot {
    public var me: Player? {
        guard let ap = activePlayer else { return nil }
        let ids = ap.identifiers
        guard !ids.isEmpty else { return nil }
        return allPlayers.first { p in ids.contains { p.isSameAs($0) } }
    }

    public var myTeam: Team? { me?.team }

    public var enemies: [Player] {
        guard let t = myTeam, t != .unknown else { return [] }
        return allPlayers.filter { $0.team != t && $0.team != .unknown }
    }

    public var allies: [Player] {
        guard let me, me.team != .unknown else { return [] }
        return allPlayers.filter { $0.team == me.team && $0 != me }
    }

    /// loading screen / partial data yields empty `allplayers` or no `gamedata`.
    public var isReady: Bool { !allPlayers.isEmpty && gameData != nil }

    public var isSummonersRift: Bool { gameData?.gameMode == "CLASSIC" && gameData?.mapNumber == 11 }
    /// the practice tool runs on summoner's rift; it gets the live features but is never recorded.
    public var isPracticeTool: Bool { gameData?.gameMode == "PRACTICETOOL" && gameData?.mapNumber == 11 }
    /// howling abyss (aram and its variants). detected by map, since a variant such as mayhem may report another game mode.
    public var isHowlingAbyss: Bool { gameData?.mapNumber == 12 }
    public var hasLiveFeatures: Bool { isSummonersRift || isPracticeTool || isHowlingAbyss }
    /// only ranked-style summoner's rift games get a record, goal result and death review.
    public var isRecordable: Bool { isSummonersRift }
}

/// case-insensitive. equal if the full strings are equal, or the game-name part (before `#`) is equal
/// when either side lacks a tag. nil/empty never matches.
public func namesMatch(_ a: String?, _ b: String?) -> Bool {
    guard let a = a?.trimmingCharacters(in: .whitespaces).lowercased(), !a.isEmpty,
          let b = b?.trimmingCharacters(in: .whitespaces).lowercased(), !b.isEmpty else { return false }
    if a == b { return true }
    let aHasTag = a.contains("#"), bHasTag = b.contains("#")
    guard !(aHasTag && bHasTag) else { return false }
    return gameNamePart(a) == gameNamePart(b)
}

/// every name the live client may use for a player: riot id, summoner name, then game name (with tag when known).
private func playerIdentifiers(riotId: String?, summonerName: String?, gameName: String?,
                               tagLine: String?) -> [String] {
    var ids: [String] = []
    if let riotId { ids.append(riotId) }
    if let summonerName { ids.append(summonerName) }
    if let gameName, !gameName.isEmpty {
        if let tagLine, !tagLine.isEmpty { ids.append("\(gameName)#\(tagLine)") } else { ids.append(gameName) }
    }
    return ids
}

private func gameNamePart(_ s: String) -> String {
    String(s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
}
