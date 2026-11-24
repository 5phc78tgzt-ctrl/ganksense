import AppKit
import SwiftUI
import Observation
import CompanionCore

/// the loading screen scout on the game's screen: both teams, rank and season win rate per player. it shows from the
/// moment the client reports the game in progress until the game clock starts, so nobody has to open the menu bar
/// while the loading screen runs. click-through, never takes focus.
@MainActor
final class ScoutCardController {
    private let model: AppModel
    private let panel = ScoutPanel()
    private let host: NSHostingView<ScoutCard>
    /// screenshot flag `--scout-preview`: shows the card with sample data until quit.
    private var preview = false
    private var shown = false
    private var hideTask: Task<Void, Never>?
    private var refrontTask: Task<Void, Never>?
    private var cardSize = NSSize.zero
    private var cardScale: CGFloat = 1
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        host = NSHostingView(rootView: ScoutCard(board: nil, iconURL: { _ in nil }, championName: { _ in nil }, scale: 1))
        host.safeAreaRegions = []
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
    }

    func start() {
        observe()
        // league's fullscreen is its own space that appears after the card is first ordered front; follow it like the hud does.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refront() }
            })
        }
    }

    /// re-places the card on the game's current screen and re-orders it front, which pulls it into the active space.
    private func refront() {
        guard shown else { return }
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        let area = GameScreen.current().visible
        let k = cardScale
        // top centre, clear of the loading screen's champion cards, which sit in the middle band.
        let frame = NSRect(x: (area.midX - cardSize.width / 2).rounded(), y: (area.maxY - cardSize.height - 24 * k).rounded(),
                           width: ceil(cardSize.width), height: ceil(cardSize.height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func showPreview(_ board: ScoutBoard) {
        preview = true
        model.coordinator.scout.showPreview(board)
    }

    private func observe() {
        let c = model.coordinator
        let (board, visible, scale) = withObservationTracking {
            let loading = !c.gameClockRunning && (c.snapshot?.gameData?.gameTime ?? 0) <= 0
            let inGame = c.phase == .inGame || c.phase == .client(.inProgress)
            return (c.scout.board, inGame && loading && c.settings.overlayEnabled, c.settings.overlayScale)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard let board, visible || preview else { hide(); return }
        let k = CGFloat(min(max(scale, 0.6), 1.6))
        let card = ScoutCard(board: board, iconURL: { [model] in model.championIconURL(key: $0) },
                             championName: { [model] in model.coordinator.championCatalog?.champion(key: $0)?.name },
                             scale: k)
        host.rootView = card
        cardSize = NSHostingView(rootView: card).fittingSize
        cardScale = k
        place()
        show()
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        guard !shown else { return }
        shown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // the game window and its fullscreen space only appear a few seconds in: keep re-fronting until the card hides.
        refrontTask?.cancel()
        refrontTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.shown else { return }
                self.refront()
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// fades out when the game clock starts (or the game ends) rather than vanishing mid-glance.
    private func hide() {
        guard shown else { return }
        shown = false
        refrontTask?.cancel()
        refrontTask = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(reduce ? 0 : 0.35))
            guard !Task.isCancelled, let self, !self.shown else { return }
            self.panel.orderOut(nil)
        }
    }
}

struct ScoutCard: View {
    let board: ScoutBoard?
    let iconURL: (Int) -> URL?
    let championName: (Int) -> String?
    let scale: CGFloat

    var body: some View {
        let k = scale
        HStack(alignment: .top, spacing: 18 * k) {
            ForEach(Array((board?.teams ?? []).enumerated()), id: \.element.id) { index, team in
                if index > 0 {
                    Rectangle().fill(LeagueTheme.bronze.opacity(0.5)).frame(width: 1)
                }
                TeamColumn(team: team, enemy: index > 0, iconURL: iconURL, championName: championName, k: k)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14 * k)
        .padding(.vertical, 12 * k)
        .leaguePanel(scale: k)
        .padding(8 * k)
    }
}

private struct TeamColumn: View {
    let team: ScoutTeam
    let enemy: Bool
    let iconURL: (Int) -> URL?
    let championName: (Int) -> String?
    let k: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * k) {
            Text(team.title)
                .leagueLabel(scale: k, color: enemy ? LeagueTheme.red.opacity(0.9) : LeagueTheme.teal)
                .padding(.bottom, 2 * k)
            ForEach(team.players) { player in
                PlayerRow(player: player, iconURL: iconURL(player.championKey), championName: championName, k: k)
            }
        }
        .frame(width: 300 * k, alignment: .leading)
    }
}

private struct PlayerRow: View {
    let player: ScoutPlayer
    let iconURL: URL?
    let championName: (Int) -> String?
    let k: CGFloat

    var body: some View {
        HStack(spacing: 9 * k) {
            ItemIcon(url: iconURL, size: 30 * k, frameColor: player.isMe ? LeagueTheme.gold : LeagueTheme.bronze)
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(rankText)
                    .font(LeagueTheme.body(12.5 * k, .semibold))
                    .foregroundStyle(player.rank?.isRanked == true ? LeagueTheme.text : LeagueTheme.muted)
                HStack(spacing: 4 * k) {
                    // flags first: they are the point; the name gives way when space runs out.
                    ForEach(Array(player.flags.prefix(2).enumerated()), id: \.offset) { _, flag in
                        FlagChip(flag: flag, partner: partner(flag), k: k)
                    }
                    Text(player.gameName.isEmpty ? "Hidden name" : player.gameName)
                        .font(LeagueTheme.body(10.5 * k))
                        .foregroundStyle(LeagueTheme.muted)
                        .layoutPriority(-1)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6 * k)
            if let rank = player.rank, let wr = rank.winRatePercent {
                VStack(alignment: .trailing, spacing: 1 * k) {
                    Text("\(wr)%")
                        .font(LeagueTheme.body(12.5 * k, .semibold))
                        .foregroundStyle(Self.color(wr, games: rank.games))
                    Text("\(rank.games) games")
                        .font(LeagueTheme.body(10.5 * k))
                        .foregroundStyle(LeagueTheme.muted)
                }
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 5 * k)
        .padding(.vertical, 3 * k)
        .background {
            if player.isMe {
                RoundedRectangle(cornerRadius: 2 * k)
                    .fill(LeagueTheme.gold.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 2 * k).strokeBorder(LeagueTheme.gold.opacity(0.45), lineWidth: 1))
            }
        }
    }

    private func partner(_ flag: ScoutFlag) -> String? {
        guard case .duo(let key) = flag else { return nil }
        return championName(key)
    }

    private var rankText: String {
        guard let rank = player.rank else { return "Looking up rank…" }
        return rank.label
    }

    /// teal or red only when the sample is big enough to mean something.
    static func color(_ wr: Int, games: Int) -> Color {
        guard games >= 20 else { return LeagueTheme.text }
        if wr >= 55 { return LeagueTheme.teal }
        if wr <= 45 { return LeagueTheme.red }
        return LeagueTheme.text
    }
}

/// one flag as a small tinted chip: gold for smurf and one-trick, teal or red for a streak, blue for a duo.
private struct FlagChip: View {
    let flag: ScoutFlag
    let partner: String?
    let k: CGFloat

    var body: some View {
        Text(flag.label(partner: partner))
            .font(LeagueTheme.body(9.5 * k, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4 * k)
            .padding(.vertical, 1 * k)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 2 * k))
            .fixedSize()
            .accessibilityLabel(flag.detail(partner: partner))
    }

    private var color: Color {
        switch flag {
        case .likelySmurf, .oneTrick: LeagueTheme.gold
        case .streak(let won, _): won ? LeagueTheme.teal : LeagueTheme.red
        case .newOnChampion: LeagueTheme.muted
        case .duo: LeagueTheme.magic
        }
    }
}

private final class ScoutPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
