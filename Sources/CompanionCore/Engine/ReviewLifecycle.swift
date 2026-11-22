/// when the post-game death review is on screen, as pure decisions over the coordinator's phase.
///
/// the review belongs to league's end-of-game flow: it appears once the game process is gone and the client is on
/// the win/loss screen (gameflow `waitingforstats`, `preendofgame`, `endofgame`; the coordinator's `.postgame`
/// phase covers the same stretch from the app's side), and it goes away by itself as soon as that flow is left
/// (lobby, champ select, queue, a new game, league closed). closing never touches the stored record.
public enum ReviewLifecycle {
    public static let endFlowPhases: Set<GameflowPhase> = [.waitingForStats, .preEndOfGame, .endOfGame]

    public static func inEndFlow(_ phase: AppPhase) -> Bool {
        switch phase {
        case .postGame: true
        case .client(let p): endFlowPhases.contains(p)
        case .asleep, .inGame: false
        }
    }

    /// show the review for the game that just ended: in the end-of-game flow, the game process has exited (the
    /// window takes clicks, so it never floats over a running game) and the record has at least one death.
    public static func shouldShow(phase: AppPhase, hasReviewableRecord: Bool, gameProcessRunning: Bool) -> Bool {
        hasReviewableRecord && !gameProcessRunning && inEndFlow(phase)
    }

    public static func shouldClose(phase: AppPhase) -> Bool {
        !inEndFlow(phase)
    }

    /// a review opened by hand (menu bar popover) stays until closed, except that it never floats over a game.
    public static func shouldCloseManual(phase: AppPhase) -> Bool {
        phase == .inGame
    }

    public static func latestReviewable(in records: [GameRecord]) -> GameRecord? {
        records.filter { !$0.deaths.isEmpty }.max { $0.date < $1.date }
    }

    public static func hint(for record: GameRecord) -> String {
        let result: String = switch record.win {
        case true?: "Victory"
        case false?: "Defeat"
        case nil: record.isVoid ? "Remake" : "Game over"
        }
        let s = max(Int(record.durationSec.rounded(.down)), 0)
        let clock = "\(s / 60 < 10 ? "0" : "")\(s / 60):\(s % 60 < 10 ? "0" : "")\(s % 60)"
        let n = record.deaths.count
        return "\(result) · \(record.champion) · \(clock), \(n) death\(n == 1 ? "" : "s")"
    }
}
