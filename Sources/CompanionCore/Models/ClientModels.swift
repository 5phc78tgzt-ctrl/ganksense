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
    public init(championKey: Int?, role: Role?) {
        self.championKey = championKey
        self.role = role
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
