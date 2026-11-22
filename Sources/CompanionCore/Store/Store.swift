import Foundation


public enum OverlayAnchor: String, Codable, CaseIterable, Sendable {
    case rightUpper, rightMiddle, leftUpper, topCenter
}

public struct Settings: Codable, Sendable, Equatable {
    /// goal for the next game. `nil` = no goal coach.
    public var goal: Goal?
    /// target per goal preset, keyed by goal preset raw value (e.g. "csat10"). one global target per preset;
    /// it takes precedence over `goal.target` (see effective goal()).
    public var goalTargets: [String: Double]
    public var tilt: TiltSettings
    public var overlayEnabled: Bool
    public var overlayCorner: OverlayAnchor
    public var overlayScale: Double
    /// show the informational "enemy jungler last seen" line in the overlay.
    public var showJunglerLine: Bool
    /// show the overlay for as long as tab is held in game (reads the tab key state only while league is in front).
    public var showWhileHoldingTab: Bool
    public var useOPGG: Bool
    public var launchAtLogin: Bool
    public var fullscreenTipShown: Bool

    public init(goal: Goal? = nil, goalTargets: [String: Double] = [:], tilt: TiltSettings = TiltSettings(),
                overlayEnabled: Bool = true, overlayCorner: OverlayAnchor = .rightUpper, overlayScale: Double = 1.0,
                useOPGG: Bool = true, launchAtLogin: Bool = false,
                fullscreenTipShown: Bool = false, showJunglerLine: Bool = true, showWhileHoldingTab: Bool = true) {
        self.goal = goal; self.goalTargets = goalTargets; self.tilt = tilt
        self.overlayEnabled = overlayEnabled; self.overlayCorner = overlayCorner; self.overlayScale = overlayScale
        self.showWhileHoldingTab = showWhileHoldingTab; self.useOPGG = useOPGG; self.launchAtLogin = launchAtLogin
        self.fullscreenTipShown = fullscreenTipShown; self.showJunglerLine = showJunglerLine
    }

    /// stored target for a preset, else the preset's default.
    public func target(for preset: GoalPreset) -> Double {
        goalTargets[preset.rawValue] ?? preset.defaultTarget
    }

    /// the goal actually tracked in a game: `goal` with its preset's stored target applied.
    public func effectiveGoal() -> Goal? {
        guard var g = goal else { return nil }
        if let t = goalTargets[g.preset.rawValue] { g.target = t }
        return g
    }

    /// sets the global target for a preset; also updates `goal` when it uses that preset.
    public mutating func setTarget(_ value: Double, for preset: GoalPreset) {
        goalTargets[preset.rawValue] = value
        if goal?.preset == preset { goal?.target = value }
    }

    /// clears every stored target; the current goal goes back to its preset's default.
    public mutating func resetTargets() {
        goalTargets = [:]
        if let p = goal?.preset { goal?.target = p.defaultTarget }
    }

    private enum CodingKeys: String, CodingKey {
        case goal, goalTargets, tilt, overlayEnabled, overlayCorner, overlayScale, useOPGG
        case launchAtLogin, fullscreenTipShown, showJunglerLine, showWhileHoldingTab
    }

    /// every key optional: a missing or unreadable value falls back to its default instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        goal = (try? c.decodeIfPresent(Goal.self, forKey: .goal)) ?? nil
        goalTargets = (try? c.decodeIfPresent([String: Double].self, forKey: .goalTargets)) ?? d.goalTargets
        tilt = (try? c.decodeIfPresent(TiltSettings.self, forKey: .tilt)) ?? d.tilt
        overlayEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .overlayEnabled)) ?? d.overlayEnabled
        overlayCorner = (try? c.decodeIfPresent(OverlayAnchor.self, forKey: .overlayCorner)) ?? d.overlayCorner
        overlayScale = (try? c.decodeIfPresent(Double.self, forKey: .overlayScale)) ?? d.overlayScale
        useOPGG = (try? c.decodeIfPresent(Bool.self, forKey: .useOPGG)) ?? d.useOPGG
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        fullscreenTipShown = (try? c.decodeIfPresent(Bool.self, forKey: .fullscreenTipShown)) ?? d.fullscreenTipShown
        showJunglerLine = (try? c.decodeIfPresent(Bool.self, forKey: .showJunglerLine)) ?? d.showJunglerLine
        showWhileHoldingTab = (try? c.decodeIfPresent(Bool.self, forKey: .showWhileHoldingTab)) ?? d.showWhileHoldingTab
    }
}


public struct GameRecord: Codable, Sendable, Identifiable, Equatable {
    /// `"<start epoch seconds>-<champion id>"`; stable across reconnects within one game.
    public var id: String
    /// game start (wall clock).
    public var date: Date
    /// data dragon champion id (e.g. "jinx").
    public var champion: String
    public var role: Role?
    /// from the game end event (result "win"/"lose"); nil when the game ended without one.
    public var win: Bool?
    /// latched goal result; nil when no goal was set or the game is void.
    public var goalResult: GoalProgress?
    public var deaths: [DeathEvent]
    public var durationSec: Double
    /// remake / early end (< 5 min): excluded from goal streaks and session stats.
    public var isVoid: Bool
    /// roster and kill/objective events (champion names only) the likely death causes are estimated from; nil when
    /// no event log was captured (previews).
    public var context: GameContext?

    public init(id: String, date: Date, champion: String, role: Role?, win: Bool?, goalResult: GoalProgress?,
                deaths: [DeathEvent], durationSec: Double, isVoid: Bool, context: GameContext? = nil) {
        self.id = id; self.date = date; self.champion = champion; self.role = role; self.win = win
        self.goalResult = goalResult; self.deaths = deaths; self.durationSec = durationSec; self.isVoid = isVoid
        self.context = context
    }
}


/// json persistence under one directory (`settings.json`, `records.json`). writes are atomic. a corrupt settings
/// file reads as defaults. records decode one by one: unreadable (corrupt) ones are
/// skipped, and the original file is first copied to `records.corrupt-<epoch>.json` so no history is lost.
public actor Store {
    public nonisolated let directory: URL
    private var cachedRecords: [GameRecord]?

    /// ~/library/application support/<app name>/
    public static var defaultDirectory: URL {
        applicationSupport.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    public init(directory: URL) {
        self.directory = directory
    }

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var recordsURL: URL { directory.appendingPathComponent("records.json") }

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(_ s: Settings) {
        write(s, to: settingsURL)
    }

    public func records() -> [GameRecord] {
        if let cachedRecords { return cachedRecords }
        var loaded: [GameRecord] = []
        if let data = try? Data(contentsOf: recordsURL) {
            let boxes = try? JSONDecoder().decode([LossyRecord].self, from: data)
            loaded = boxes?.compactMap(\.value) ?? []
            if boxes == nil || loaded.count != boxes?.count { backUpRecords(data) }
        }
        cachedRecords = loaded
        return loaded
    }

    /// appends; a record whose `id` already exists replaces it (a game is never stored twice).
    public func append(_ r: GameRecord) {
        var all = records()
        if let i = all.firstIndex(where: { $0.id == r.id }) { all[i] = r } else { all.append(r) }
        cachedRecords = all
        write(all, to: recordsURL)
    }

    /// replaces the record with the same `id`; no-op if absent.
    public func update(_ r: GameRecord) {
        var all = records()
        guard let i = all.firstIndex(where: { $0.id == r.id }) else { return }
        all[i] = r
        cachedRecords = all
        write(all, to: recordsURL)
    }

    /// deletes the game history: `records.json` and the backups of unreadable record files. settings stay.
    public func purgeHistory() {
        cachedRecords = []
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name == "records.json" || (name.hasPrefix("records.corrupt-") && name.hasSuffix(".json")) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// keeps a copy of a records file that didn't fully decode, before the next save overwrites it.
    private func backUpRecords(_ data: Data) {
        let url = directory.appendingPathComponent("records.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url, options: .atomic)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// one element of `records.json`: nil when that record doesn't decode.
private struct LossyRecord: Decodable {
    let value: GameRecord?
    init(from decoder: Decoder) throws { value = try? GameRecord(from: decoder) }
}
