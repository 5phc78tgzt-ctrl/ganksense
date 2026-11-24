import Foundation

public enum GameflowPhase: String, Codable, Sendable {
    case none = "None", lobby = "Lobby", matchmaking = "Matchmaking", readyCheck = "ReadyCheck"
    case champSelect = "ChampSelect", gameStart = "GameStart", inProgress = "InProgress"
    case reconnect = "Reconnect", waitingForStats = "WaitingForStats"
    case preEndOfGame = "PreEndOfGame", endOfGame = "EndOfGame", unknown

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(GameflowPhase.init(rawValue:)) ?? .unknown
    }
}

public struct ChampSelectInfo: Sendable, Equatable {
    public var championKey: Int?
    public var role: Role?
    /// the enemy pick in my position, once revealed.
    public var enemyLaner: Int?
    /// the locked enemy picks, only when the client gives no enemy positions (normal draft): the advisor
    /// guesses the lane opponent from these.
    public var enemyPicks: [Int]
    /// banned or locked champions (both teams).
    public var unavailable: Set<Int>
    /// my teammates' picks or hovers (champion keys), without me.
    public var allies: [Int]
    /// ranked or normal draft: an assigned role and no aram bench.
    public var isDraft: Bool
    public init(championKey: Int?, role: Role?, enemyLaner: Int? = nil, enemyPicks: [Int] = [], unavailable: Set<Int> = [],
                allies: [Int] = [], isDraft: Bool = false) {
        self.championKey = championKey
        self.role = role
        self.enemyLaner = enemyLaner
        self.enemyPicks = enemyPicks
        self.unavailable = unavailable
        self.allies = allies
        self.isDraft = isDraft
    }
}

public struct MatchSummary: Codable, Sendable, Equatable {
    public var gameId: Int
    public var start: Date
    public var durationSec: Int
    public var queueId: Int
    public var win: Bool
    public var championKey: Int
    public var remake: Bool

    public init(gameId: Int, start: Date, durationSec: Int, queueId: Int, win: Bool, championKey: Int, remake: Bool) {
        self.gameId = gameId
        self.start = start
        self.durationSec = durationSec
        self.queueId = queueId
        self.win = win
        self.championKey = championKey
        self.remake = remake
    }
}


/// the client's matchmaking search while queued or in a ready check.
public struct QueueSearch: Sendable, Equatable {
    /// seconds in queue so far.
    public var timeInQueue: Double
    /// the client's estimate in seconds; nil when it gives none.
    public var estimate: Double?
    /// "None" until the player answers a ready check, then "Accepted" or "Declined"; nil outside one.
    public var readyCheckResponse: String?

    public init(timeInQueue: Double, estimate: Double? = nil, readyCheckResponse: String? = nil) {
        self.timeInQueue = timeInQueue; self.estimate = estimate; self.readyCheckResponse = readyCheckResponse
    }
}

/// queue time and the ready check (local client).
public protocol MatchmakingSource: Sendable {
    func queueSearch() async -> QueueSearch?
    /// accepts the open ready check; true when the client took it.
    func acceptReadyCheck() async -> Bool
}
