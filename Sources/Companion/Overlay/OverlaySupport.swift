import AppKit
import CompanionCore

/// the display hosting the league game window. reads only window owner names and bounds, never titles or contents. macOS may ask for
/// screen recording for this call; without it the overlay uses the main screen.
@MainActor
enum GameScreen {
    private static let owners: Set<String> = ["LeagueofLegends", "League of Legends"]

    /// a display's frame and visible frame in appkit coordinates.
    struct Area {
        let frame: NSRect
        let visible: NSRect
    }

    /// read live from core graphics: league's fullscreen switches the display mode, and nsscreen only catches up
    /// seconds later.
    static func current() -> Area {
        var display = NSScreen.main.flatMap(displayID) ?? CGMainDisplayID()
        if let bounds = gameWindowBounds() {
            var found: CGDirectDisplayID = 0
            var count: UInt32 = 0
            // cg window bounds and display bounds share the same top-left global space.
            if CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &found, &count) == .success, count > 0 {
                display = found
            }
        }
        return area(of: display)
    }

    static func area(of screen: NSScreen) -> Area {
        displayID(screen).map(area(of:)) ?? Area(frame: screen.frame, visible: screen.visibleFrame)
    }

    private static func area(of display: CGDirectDisplayID) -> Area {
        // appkit flips window frames with its own cached primary height, which lags a mode change; flipping with
        // the same value lands the panel where core graphics says the display is.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        let b = CGDisplayBounds(display)
        let frame = NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        // the cached visible frame (menu bar, dock) is only right once nsscreen matches the live mode.
        let screen = NSScreen.screens.first { $0.frame == frame }
        return Area(frame: frame, visible: screen?.visibleFrame ?? frame)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func gameWindowBounds() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: CGRect?
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width >= 320, rect.height >= 240 else { continue }
            if best.map({ rect.width * rect.height > $0.width * $0.height }) ?? true { best = rect }
        }
        return best
    }
}

/// static preview data (`coordinator.overlaypreview()`), computed once off the main actor.
@MainActor
enum PreviewData {
    private static var cached: OverlayPreview?
    private static var loading: Task<OverlayPreview?, Never>?

    static func overlay() async -> OverlayPreview? {
        if let cached { return cached }
        let task = loading ?? Task.detached(priority: .userInitiated) { Coordinator.overlayPreview() }
        loading = task
        let value = await task.value
        cached = value
        loading = nil
        return value
    }

    /// a finished demo game for the death review preview: the preview moment's deaths and goal, with `win` as
    /// the result (nil: no result, shown as "game over").
    static func reviewRecord(win: Bool? = true) async -> GameRecord? {
        guard let p = await overlay() else { return nil }
        let champion = p.snapshot.me?.championID ?? "Jinx"
        // synthetic kill feed with a mix of causes: a gank by a smite jungler, a teamfight, a solo kill and a
        // death with no clear signal. champion names only, like real stored records.
        let me = champion
        var roster = [GameContext.Participant(champion: me, isMe: true, isAlly: true, spells: ["Heal", "Flash"], position: "BOTTOM")]
        roster += [("Lux", "UTILITY"), ("Ahri", "MIDDLE"), ("Ornn", "TOP"), ("Sejuani", "JUNGLE")].map {
            GameContext.Participant(champion: $0.0, isAlly: true, spells: $0.0 == "Sejuani" ? ["Smite", "Flash"] : ["Flash", "Ignite"], position: $0.1)
        }
        roster += [("Draven", "BOTTOM", false), ("Leona", "UTILITY", false), ("Zed", "MIDDLE", false),
                   ("Camille", "TOP", false), ("Lee Sin", "JUNGLE", true)].map {
            GameContext.Participant(champion: $0.0, isAlly: false, spells: $0.2 ? ["Smite", "Flash"] : ["Flash", "Heal"], position: $0.1)
        }
        let events: [GameContext.LoggedEvent] = [
            .init(id: 1, name: "ChampionKill", time: 252, killer: "Lee Sin", victim: me, assisters: ["Draven"]),
            .init(id: 2, name: "ChampionKill", time: 612, killer: "Draven", victim: "Lux", assisters: []),
            .init(id: 3, name: "ChampionKill", time: 618, killer: "Leona", victim: me, assisters: ["Draven", "Zed"]),
            .init(id: 4, name: "ChampionKill", time: 623, killer: "Zed", victim: "Ahri", assisters: []),
            .init(id: 5, name: "ChampionKill", time: 1_104, killer: "Zed", victim: me, assisters: []),
            .init(id: 6, name: "ChampionKill", time: 1_490, killer: "Minions", victim: me, assisters: []),
        ]
        let deaths = events.filter { $0.victim == me }.map {
            DeathEvent(id: $0.id, time: $0.time, killer: $0.killer, assisters: $0.assisters)
        }
        let context = GameContext(participants: roster, events: events,
                                  spikes: [.init(time: 1_020, champion: "Zed", detail: "2nd item: Serylda's Grudge")])
        return GameRecord(id: "preview-\(champion)", date: Date(), champion: champion, role: .adc, win: win,
                          goalResult: p.goalProgress, deaths: deaths,
                          durationSec: max(p.snapshot.gameData?.gameTime ?? 0, 1_712), isVoid: false, context: context)
    }
}
