/// when the in-game overlay is visible. hidden by default; shown while any reason holds.
public enum OverlayVisibility {
    public static func shouldShow(tabHeld: Bool, boostActive: Bool, deadWithGold: Bool) -> Bool {
        tabHeld || boostActive || deadWithGold
    }
}

/// turns raw ~20 hz samples of the tab key into a steady "held" signal.
/// - tab with command, option or control down (cmd-tab app switching and the like) never counts, and that press
///   stays ignored until tab is released, even if the modifier is let go first.
/// - a fresh filter ignores a tab that is already down (held through the loading screen, or into an app
///   switch): only a press that starts while sampling counts.
/// - shows on the first down sample (no added latency); hides only after `releasesamples` consecutive up
///   samples, so a missed sample or key bounce does not flicker the overlay.
public struct TabHoldFilter: Sendable, Equatable {
    public static let releaseSamples = 2

    public private(set) var held = false
    private var suppressed = true
    private var upCount = 0

    public init() {}

    @discardableResult
    public mutating func sample(tabDown: Bool, modifierDown: Bool) -> Bool {
        if !tabDown {
            suppressed = false
            upCount += 1
            if upCount >= Self.releaseSamples { held = false }
            return held
        }
        upCount = 0
        if modifierDown { suppressed = true }
        if suppressed {
            held = false
        } else {
            held = true
        }
        return held
    }

    public mutating func reset() { self = TabHoldFilter() }
}

public enum TabGate {
    /// all of: the app is in game (not client, lobby, champ select, post-game or asleep); the live client api has
    /// a running game (a snapshot with game time > 0, so not the loading screen); league's game window is the
    /// frontmost app; and the setting is on.
    public static func isActive(phase: AppPhase, hasActiveSnapshot: Bool, gameFrontmost: Bool, enabled: Bool) -> Bool {
        guard enabled, gameFrontmost, hasActiveSnapshot else { return false }
        return phase == .inGame
    }

    /// a snapshot counts once the game clock runs (the live client api can answer during the loading screen).
    public static func isActiveSnapshot(_ snapshot: LiveGameSnapshot?) -> Bool {
        guard let snapshot, snapshot.hasLiveFeatures else { return false }
        return (snapshot.gameData?.gameTime ?? 0) > 0
    }
}
