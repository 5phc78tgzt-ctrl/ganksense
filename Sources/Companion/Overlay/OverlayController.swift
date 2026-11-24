import AppKit
import SwiftUI
import Observation
import CompanionCore

/// shows the league-style hud in a click-through, non-activating panel while a summoner's rift or howling abyss game runs.
///
/// visible when `phase == .ingame && snapshot?.issummonersrift == true && settings.overlayenabled`, or while a
/// preview runs. event-driven: it re-renders only when the coordinator's observed state changes (1 hz in game)
/// and is ordered out (no drawing) otherwise.
///
/// smart fade (live game): hidden by default, the panel kept ordered in at alpha 0 so showing it costs nothing.
/// the whole hud shows for 4 s when i die, for as long as i'm dead with enough gold for the next item, and for as
/// long as tab is held (`tabwatcher`, gated by `tabgate`); that decision is `overlayvisibility.shouldshow`.
/// alerts (a new next item, an enemy spike, a new jungler sighting or its death) show only their own row with a
/// countdown line and stack below each other in arrival order. the panel fades out once nothing holds it. the opacity is the panel's alpha, animated by the compositor (0.15 s;
/// instant with reduce motion). previews always show at full opacity.
@MainActor
final class OverlayController {
    private let model: AppModel
    private var coordinator: Coordinator { model.coordinator }
    private let state = OverlayState()
    private let panel: OverlayPanel

    private enum Preview { case off, timed, persistent }
    private var preview: Preview = .off
    private var previewContent: OverlayContent?
    private var previewTask: Task<Void, Never>?

    private var lastNextID: Int?
    private var lastSpikeID: String?
    private var lastDeaths: Int?
    private var lastDeadAffordable = false
    private var lastJunglerKey: String?
    private var alertTimers: [OverlayAlert: AlertTimer] = [:]
    private var alertTasks: [OverlayAlert: Task<Void, Never>] = [:]
    private var alertToken = 0
    private var collapseTask: Task<Void, Never>?
    /// `--overlay-preview alerts`: the preview runs the alert mode on a loop instead of the whole hud.
    private let alertsDemo: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "--overlay-preview").map { $0 + 1 < a.count && a[$0 + 1] == "alerts" } ?? false
    }()
    private var boosted = false
    private var holdTask: Task<Void, Never>?
    private let tab = TabWatcher()
    private var tabHeld = false

    private var shown = false
    private var panelAlpha: CGFloat = -1
    private var scale: CGFloat = 1
    private var corner: OverlayAnchor = .rightUpper
    private var placedKey: String?
    private var screenObserver: NSObjectProtocol?

    static let boostDuration: Duration = .seconds(4)
    static let previewDuration: Duration = .seconds(5)

    init(model: AppModel) {
        self.model = model
        panel = OverlayPanel()
        let host = NSHostingView(rootView: OverlayView(state: state))
        host.sizingOptions = []
        host.safeAreaRegions = []
        // a plain container as the content view, the hosting view resized by autoresizing: as the content view
        // itself, nshostingview feeds its size back into the window's content-size limits during the constraint
        // pass, which can loop until appkit throws (seen in release builds when the overlay first appears).
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
    }

    func start() {
        tab.onChange = { [weak self] held in
            guard let self else { return }
            self.tabHeld = held
            AppLog.app.notice("Tab \(held ? "held" : "released", privacy: .public)")
            self.refreshActive()
        }
        tab.onFrontmostChange = { [weak self] in self?.update() }
        observe()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyLayout()
                self?.placePanel(force: true)
            }
        }
        model.showOverlayPreview = { [weak self] in self?.showPreview(persistent: false) }
    }

    /// shows the overlay with static demo data at full opacity: 5 s, with a countdown (settings button) or until quit
    /// (`--overlay-preview`, always full opacity).
    func showPreview(persistent: Bool) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let data = await PreviewData.overlay(), let self, !Task.isCancelled else { return }
            self.previewContent = self.content(from: data)
            self.preview = persistent ? .persistent : .timed
            self.update()
            if self.alertsDemo { self.runAlertsDemo(); return }
            guard !persistent else { return }
            let end = Date().addingTimeInterval(Double(Self.previewDuration.components.seconds))
            self.state.previewEndsAt = end
            self.model.overlayPreviewEndsAt = end
            self.update()
            try? await Task.sleep(for: Self.previewDuration)
            guard !Task.isCancelled else { return }
            self.state.previewEndsAt = nil
            self.model.overlayPreviewEndsAt = nil
            self.preview = .off
            self.previewContent = nil
            self.resetEdges()
            self.update()
        }
    }


    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// reads every coordinator property the overlay depends on (so they are all tracked) and applies them.
    private func update() {
        let c = coordinator
        let settings = c.settings
        // `state` is written, never read, here: only coordinator properties are tracked.
        let layoutChanged = applyLayout()

        let liveVisible = c.phase == .inGame && c.snapshot?.hasLiveFeatures == true
            && (c.snapshot?.gameData?.gameTime ?? 0) > 0 && settings.overlayEnabled
        // hold-tab only during a running game with league in front; otherwise the timer is stopped and tab ignored.
        tab.setActive(preview == .off && liveVisible && TabGate.isActive(
            phase: c.phase, hasActiveSnapshot: TabGate.isActiveSnapshot(c.snapshot),
            gameFrontmost: tab.gameFrontmost, enabled: settings.showWhileHoldingTab))

        if preview != .off, let previewContent {
            set(\.content, previewContent)
            show(reason: "preview")
            refreshActive()
        } else if liveVisible, let snapshot = c.snapshot {
            let content = OverlayContent(
                goal: c.goalProgress,
                suggestion: c.suggestion?.quantizedForDisplay(),
                nextIconURL: c.suggestion.flatMap { model.itemIconURL($0.next.id) },
                thenIconURL: c.suggestion?.then.flatMap { model.itemIconURL($0.id) },
                adShare: c.threat.map { ($0.adShare * 100).rounded() / 100 },
                spike: c.spikeAlerts.first,
                jungler: c.jungler,
                augments: snapshot.isHowlingAbyss ? c.augments : [],
                goldLead: c.goldLead)
            detectTriggers(snapshot: snapshot, content: content, rawSuggestion: c.suggestion)
            set(\.content, content)
            show(reason: "live")
            refreshActive()
        } else {
            hide()
            resetEdges()
        }
        if shown, layoutChanged { placePanel(force: true) }
    }

    /// scale and corner for the current settings and game screen. league's fullscreen switches the display mode,
    /// so this runs again whenever the panel appears and when the screen changes. true when the layout changed.
    @discardableResult
    private func applyLayout() -> Bool {
        let settings = coordinator.settings
        var requested = settings.overlayScale
        // hidden screenshot flag `--overlay-scale <value>`: previews a size without touching settings.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--overlay-scale"), i + 1 < args.count, let v = Double(args[i + 1]) { requested = v }
        let area = targetArea()
        let scale = Self.fittedScale(corner: settings.overlayCorner,
                                     scale: CGFloat(min(max(requested, 0.6), 1.6)) * Self.screenFactor(area), area: area)
        let changed = scale != self.scale || settings.overlayCorner != corner
        self.scale = scale
        corner = settings.overlayCorner
        set(\.scale, scale)
        set(\.alignment, Self.alignment(settings.overlayCorner))
        return changed
    }

    /// smart fade on the window itself: the compositor animates the panel's alpha, so a fade costs no swiftui
    /// re-rendering (a swiftui opacity spring re-rasterized every text run and gradient on every frame).
    private func applyAlpha() {
        let target: CGFloat = state.active ? 1 : 0
        guard target != panelAlpha else { return }
        panelAlpha = target
        // league's fullscreen is its own space; re-ordering pulls the panel into whichever space is active.
        if shown, target == 1 {
            if applyLayout() { placePanel(force: true) }
            panel.orderFrontRegardless()
        }
        if shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
        }
    }

    /// assigns only on change, so a 1 hz tick with identical data does not re-render the hud.
    private func set<V: Equatable>(_ key: ReferenceWritableKeyPath<OverlayState, V>, _ value: V) {
        guard state[keyPath: key] != value else { return }
        state[keyPath: key] = value
        if key == \OverlayState.active {
            applyAlpha()
            AppLog.app.notice("Overlay \(self.state.active ? "visible" : "hidden (alpha 0)", privacy: .public)")
        }
    }

    private func detectTriggers(snapshot: LiveGameSnapshot, content: OverlayContent, rawSuggestion: BuildSuggestion?) {
        var fire = false
        let nextID = content.suggestion?.next.id
        if let nextID, nextID != lastNextID { alert(.nextBuy, seconds: 4) }
        lastNextID = nextID

        let spikeID = content.spike?.id
        if let spikeID, spikeID != lastSpikeID {
            alert(.spike, seconds: Double(Coordinator.spikeAlertDuration.components.seconds))
        }
        lastSpikeID = spikeID

        let me = snapshot.me
        let deaths = me?.scores.deaths ?? 0
        if let lastDeaths, deaths > lastDeaths { fire = true }
        lastDeaths = deaths

        let deadAffordable = (me?.isDead ?? false) && (rawSuggestion.map { $0.costRemaining <= 0 } ?? false)
        if deadAffordable, !lastDeadAffordable { fire = true }
        lastDeadAffordable = deadAffordable

        // a fresh sighting (new place, seen just now) or the jungler's death pops the line; age ticks don't.
        let junglerKey = content.jungler.flatMap(Self.alertKey)
        if let junglerKey, junglerKey != lastJunglerKey { alert(.jungler, seconds: 4) }
        if content.jungler == nil || junglerKey != nil { lastJunglerKey = junglerKey }

        if fire { boost() }
    }

    private func resetEdges() {
        lastNextID = nil; lastSpikeID = nil; lastDeaths = nil; lastDeadAffordable = false; lastJunglerKey = nil
        holdTask?.cancel(); holdTask = nil
        boosted = false
        alertTasks.values.forEach { $0.cancel() }
        alertTasks = [:]; alertTimers = [:]
        collapseTask?.cancel(); collapseTask = nil
        set(\.active, false)
        collapse()
    }

    static func alertKey(_ j: JunglerStatus) -> String? {
        switch j.state {
        case .dead: "\(j.champion) dead"
        case .seen(let place, .justNow): "\(j.champion) \(place)"
        case .seen: nil
        }
    }

    /// decides what is drawn and whether the panel shows. rows change with the hud's own spring while the panel
    /// is up; when it fades out the rows stay until the fade is over, and when it fades in they are already there.
    private func refreshActive() {
        guard shown else { return }
        let full = preview != .off ? !alertsDemo
            : OverlayVisibility.shouldShow(tabHeld: tabHeld, boostActive: boosted, deadWithGold: lastDeadAffordable)
        let gold = preview != .off ? !alertsDemo : tabHeld
        if full || !alertTimers.isEmpty {
            collapseTask?.cancel(); collapseTask = nil
            if state.active {
                set(\.full, full); set(\.showGold, gold); set(\.alerts, alertTimers)
            } else {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { set(\.full, full); set(\.showGold, gold); set(\.alerts, alertTimers) }
                set(\.active, true)
            }
        } else if state.active {
            set(\.active, false)
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, !self.state.active else { return }
                self.collapse()
            }
        }
    }

    /// empties the stack without animation (the panel is already invisible).
    private func collapse() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { set(\.full, false); set(\.showGold, false); set(\.alerts, [:]) }
    }

    /// shows one alert row for `seconds` (restarting its countdown if it is already up).
    private func alert(_ kind: OverlayAlert, seconds: Double) {
        alertToken += 1
        let token = alertToken
        alertTimers[kind] = AlertTimer(token: token, start: .now, duration: seconds)
        alertTasks[kind]?.cancel()
        alertTasks[kind] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.alertTimers[kind]?.token == token else { return }
            self.alertTimers[kind] = nil
            self.alertTasks[kind] = nil
            self.refreshActive()
        }
        refreshActive()
    }

    /// `--overlay-preview alerts`: spike, then a jungler sighting 1.5 s later (stacking below), then a next buy,
    /// then quiet, on a loop.
    private func runAlertsDemo() {
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.alert(.spike, seconds: 4)
                try? await Task.sleep(for: .seconds(1.5))
                self?.alert(.jungler, seconds: 4)
                try? await Task.sleep(for: .seconds(1.5))
                self?.alert(.nextBuy, seconds: 4)
                try? await Task.sleep(for: .seconds(7))
            }
        }
    }

    /// whole hud now, back to alerts or hidden `boostduration` after the latest trigger (unless another reason holds).
    private func boost() {
        boosted = true
        refreshActive()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.boostDuration)
            guard !Task.isCancelled, let self else { return }
            self.boosted = false
            self.refreshActive()
        }
    }


    private func show(reason: String) {
        guard !shown else { return }
        shown = true
        placePanel(force: true)
        panelAlpha = state.active ? 1 : 0
        panel.alphaValue = panelAlpha
        panel.orderFrontRegardless()
        AppLog.app.notice("Overlay shown (\(reason, privacy: .public))")
    }

    private func hide() {
        guard shown else { return }
        shown = false
        panel.orderOut(nil)
        AppLog.app.notice("Overlay hidden")
    }

    /// sizes the panel for the tallest stack at the current scale and pins the modules to the anchor, on the
    /// screen hosting the league game window (else the main screen).
    private func placePanel(force: Bool) {
        guard shown || force else { return }
        guard let area = targetArea() else { return }
        let frame = Self.panelFrame(corner: corner, scale: scale, area: area)
        let key = "\(frame)"
        guard key != placedKey || force else { return }
        placedKey = key
        panel.setFrame(frame, display: false)
    }

    /// sized for a 900 pt tall screen; taller "more space" modes and big displays scale up, so the hud keeps the
    /// same share of the screen as league's own.
    /// previews use the primary screen so screenshots are predictable; the live overlay follows the game.
    private func targetArea() -> GameScreen.Area? {
        if preview != .off { return NSScreen.screens.first.map(GameScreen.area(of:)) }
        return GameScreen.current()
    }

    static func screenFactor(_ area: GameScreen.Area?) -> CGFloat {
        guard let height = area?.frame.height else { return 1 }
        return min(max(height / 900, 1), 3)
    }

    /// shrinks the hud so the right-hand stack stays clear of league's tab scoreboard (its right edge sits about
    /// 0.52 x height right of the screen centre) and ends above the
    /// respawn portraits over the minimap (0.58 x height from the top); constants in `OverlayLayout`. other corners keep the requested scale.
    static func fittedScale(corner: OverlayAnchor, scale k: CGFloat, area: GameScreen.Area?) -> CGFloat {
        guard let area, corner == .rightUpper else { return k }
        let vf = area.visible
        let gap = vf.width / 2 - OverlayLayout.scoreboardHalfSpan * vf.height
        let fitW = (gap - OverlayLayout.margin) / LeagueTheme.moduleWidth
        let fitH = vf.height * (OverlayLayout.stackBottomFraction - OverlayLayout.upperTopFraction)
            / OverlayLayout.typicalStackHeight
        return max(min(k, fitW, fitH), 0.5)
    }

    static func panelFrame(corner: OverlayAnchor, scale k: CGFloat, area: GameScreen.Area) -> NSRect {
        let vf = area.visible
        let pad = OverlayLayout.shadowPadding * k
        let width = LeagueTheme.moduleWidth * k + pad * 2
        let height = OverlayLayout.maxContentHeight * k + pad * 2
        let margin = OverlayLayout.margin
        let upperTop = vf.maxY - (vf.height * OverlayLayout.upperTopFraction).rounded()
        switch corner {
        case .rightUpper:
            return NSRect(x: vf.maxX - margin - width + pad, y: upperTop - height + pad, width: width, height: height)
        case .rightMiddle:
            return NSRect(x: vf.maxX - margin - width + pad, y: (vf.midY - height / 2).rounded(), width: width, height: height)
        case .leftUpper:
            return NSRect(x: vf.minX + margin - pad, y: upperTop - height + pad, width: width, height: height)
        case .topCenter:
            return NSRect(x: (vf.midX - width / 2).rounded(), y: vf.maxY - margin - height + pad, width: width, height: height)
        }
    }

    static func alignment(_ corner: OverlayAnchor) -> Alignment {
        switch corner {
        case .rightUpper: .topTrailing
        case .rightMiddle: .trailing
        case .leftUpper: .topLeading
        case .topCenter: .top
        }
    }


    private func content(from p: OverlayPreview) -> OverlayContent {
        let dd = model.dataDragon
        let v = p.itemCatalog.version
        var content = OverlayContent(
            goal: p.goalProgress,
            suggestion: p.suggestion,
            nextIconURL: p.suggestion.map { dd.itemIconURL(id: $0.next.id, version: v) },
            thenIconURL: p.suggestion?.then.map { dd.itemIconURL(id: $0.id, version: v) },
            adShare: p.threat.adShare,
            spike: p.spikeAlert,
            jungler: p.jungler,
            goldLead: GoldLead(team: 1240, lane: 350, roles: [
                .init(role: .top, diff: -420, isMe: false), .init(role: .jungle, diff: 610, isMe: false),
                .init(role: .mid, diff: 350, isMe: true), .init(role: .adc, diff: 80, isMe: false),
                .init(role: .support, diff: 620, isMe: false)]))
        Self.applyDebugVariant(to: &content)
        Self.applyAramPreview(to: &content)
        return content
    }

    /// hidden screenshot flag `--overlay-preview aram`: the howling abyss look (no goal or jungler line, sample augments).
    private static func applyAramPreview(to content: inout OverlayContent) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--overlay-preview"), i + 1 < args.count, args[i + 1] == "aram" else { return }
        content.goal = nil
        content.jungler = nil
        content.goldLead = GoldLead(team: -860, lane: nil, roles: [])
        content.augments = [
            AramAugment(id: 1335, name: "Goldrend", tier: 3, performance: 82.8),
            AramAugment(id: 1315, name: "Swift and Safe", tier: 3, performance: 80.4),
            AramAugment(id: 1389, name: "Hand of Baron", tier: 4, performance: 84.5),
            AramAugment(id: 1402, name: "Stats on Stats on Stats!", tier: 4, performance: 83.5),
            AramAugment(id: 1061, name: "Ok Boomerang", tier: 4, performance: 81.8),
        ]
    }

    /// hidden screenshot flag `--overlay-variant <name>`: forces one hud state so every look can be checked.
    /// names: `dead` (jungler respawn), `ontrack`, `done`, `failed`, `pending`, `longtitle`.
    private static func applyDebugVariant(to content: inout OverlayContent) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--overlay-variant"), i + 1 < args.count else { return }
        func goal(_ preset: GoalPreset, _ target: Double, _ state: GoalState, _ label: String) -> GoalProgress {
            GoalProgress(goal: Goal(preset: preset, target: target), current: 0, state: state, label: label)
        }
        switch args[i + 1] {
        case "dead":
            if let j = content.jungler { content.jungler = JunglerStatus(champion: j.champion, state: .dead(seconds: 25)) }
        case "ontrack": content.goal = goal(.deathsBefore14, 2, .onTrack, "0 / 2 deaths")
        case "done": content.goal = goal(.csAt10, 70, .achieved, "74 / 70 CS")
        case "failed": content.goal = goal(.deathsBefore14, 2, .failed, "3 / 2 deaths")
        case "pending": content.goal = goal(.goldAt15, 5500, .pending, "3,120 / 5,500 gold")
        case "longtitle": content.goal = goal(.csPerMinAt20, 7, .onTrack, "5.2 / 7.0 CS/min")
        default: break
        }
    }
}

/// borderless, non-activating, click-through hud panel above the game.
private final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // borderless and full-screen games sit above the status bar level; click-through and mostly hidden, so the top is safe.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
