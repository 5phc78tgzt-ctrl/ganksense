import Foundation

/// overlay data outside a game (see coordinator overlay preview()).
public struct OverlayPreview: Sendable {
    public var snapshot: LiveGameSnapshot
    public var suggestion: BuildSuggestion?
    public var threat: ThreatProfile
    public var goalProgress: GoalProgress
    public var spikeAlert: SpikeAlert
    public var jungler: JunglerStatus?
    public var itemCatalog: ItemCatalog
}

extension Coordinator {
    /// static overlay data for the settings "show overlay preview" button: a late demo-game moment (after the
    /// second death) with suggestion, threat, goal and one spike alert. side-effect free (no loops, no store),
    /// but it decodes the bundled catalogs and builds an engine: call it off the main actor and cache it.
    public nonisolated static func overlayPreview() -> OverlayPreview? {
        guard let (items, champs) = bundledCatalogs(),
              let steps = try? DemoTimeline.loadBundledSteps(),
              let s = previewMoment(in: steps) else { return nil }
        let engine = CounterBuildEngine(catalog: items, champions: champs)
        let threat = ThreatProfile.analyze(enemies: s.enemies, catalog: items, champions: champs,
                                           gameTime: s.gameData?.gameTime ?? 0, classifier: engine.classifier)
        let goal = GoalTracker.evaluate(Goal(preset: .deathsBefore14, target: 2), snapshot: s, catalog: items,
                                        final: false)
        let spike = SpikeAlert(id: "Zed-item-3814-2", champion: "Zed",
                               text: "Zed · 2nd item: \(items.item(3814)?.name ?? "Edge of Night")")
        let jungler = JunglerTracker.enemyJungler(in: s).map {
            JunglerStatus(champion: $0.championName, state: .seen(.dragon, .underMinute))
        }
        return OverlayPreview(snapshot: s, suggestion: engine.suggest(snapshot: s, base: nil, previous: nil),
                              threat: threat, goalProgress: goal, spikeAlert: spike, jungler: jungler,
                              itemCatalog: items)
    }

    /// the last demo snapshot with at least two deaths and no game end, else the last snapshot.
    private nonisolated static func previewMoment(in steps: [DemoStep]) -> LiveGameSnapshot? {
        let snapshots = steps.compactMap { step -> LiveGameSnapshot? in
            if case .snapshot(let s) = step { return s } else { return nil }
        }
        return snapshots.last { DeathRecorder.deaths(in: $0).count >= 2 && !$0.events.contains { $0.name == "GameEnd" } }
            ?? snapshots.last
    }
}
