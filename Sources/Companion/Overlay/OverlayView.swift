import AppKit
import SwiftUI
import Observation
import CompanionCore

/// what the overlay draws, as plain values: built from the live `coordinator` or from `overlaypreview`.
struct OverlayContent: Equatable {
    var goal: GoalProgress?
    var suggestion: BuildSuggestion?
    var nextIconURL: URL?
    var thenIconURL: URL?
    /// enemy physical share 0…1; nil hides the damage module.
    var adShare: Double?
    var spike: SpikeAlert?
    /// quiet enemy-jungler line; coarse by construction (age buckets, 5 s steps) so it rarely changes.
    var jungler: JunglerStatus?
    /// howling abyss only; empty hides the module.
    var augments: [AramAugment] = []
    /// item gold lead; drawn only while tab is held (or in a preview).
    var goldLead: GoldLead?

    var isEmpty: Bool {
        goal == nil && suggestion == nil && adShare == nil && spike == nil && jungler == nil && augments.isEmpty
    }
}

/// a pop-up that shows on its own row (without the rest of the hud) and disappears after `duration`.
enum OverlayAlert: Hashable, Sendable {
    case nextBuy, spike, jungler
}

/// one running alert: `token` changes on every re-fire, so its countdown line restarts.
struct AlertTimer: Equatable, Sendable {
    var token: Int
    var start: Date
    var duration: TimeInterval
}

/// mutable overlay state the controller drives; the view only reads it.
@MainActor @Observable
final class OverlayState {
    var content = OverlayContent()
    /// visible (smart fade); the panel sits at alpha 0 otherwise.
    var active = false
    /// the whole hud (tab held, dead, preview); otherwise only the running alerts are drawn.
    var full = false
    var alerts: [OverlayAlert: AlertTimer] = [:]
    /// tab is held, or a preview runs: the gold card may show.
    var showGold = false
    var scale: CGFloat = 1
    var alignment: Alignment = .topTrailing
    /// the settings preview closes at this time; the hud shows a draining bar until then.
    var previewEndsAt: Date?
}

/// the league-style hud stack: goal badge · next buy · augments (aram) · enemy damage · spike row · jungler line ·
/// item gold. in alert mode only the running alerts show, in the order they arrived, each with a countdown line.
struct OverlayView: View {
    let state: OverlayState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Module: Hashable { case goal, nextBuy, augments, damage, spike, jungler, gold, previewTimer }

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1) }

    /// the rows to draw, in order. one keyed list for both modes, so a row that stays (an alert when tab is
    /// pressed or released) keeps its identity and only moves, while the others fade in or out around it.
    private func modules(_ c: OverlayContent) -> [Module] {
        if state.full {
            var m: [Module] = []
            if c.goal != nil { m.append(.goal) }
            if c.suggestion != nil { m.append(.nextBuy) }
            if !c.augments.isEmpty { m.append(.augments) }
            if c.adShare != nil { m.append(.damage) }
            if c.spike != nil { m.append(.spike) }
            if c.jungler != nil { m.append(.jungler) }
            if state.showGold, c.goldLead != nil { m.append(.gold) }
            if state.previewEndsAt != nil { m.append(.previewTimer) }
            return m
        }
        return state.alerts.sorted { $0.value.token < $1.value.token }.compactMap { kind, _ in
            switch kind {
            case .nextBuy: c.suggestion == nil ? nil : .nextBuy
            case .spike: c.spike == nil ? nil : .spike
            case .jungler: c.jungler == nil ? nil : .jungler
            }
        }
    }

    var body: some View {
        let k = state.scale
        let content = state.content
        let list = modules(content)
        VStack(alignment: horizontal, spacing: 6 * k) {
            ForEach(list, id: \.self) { module in
                row(module, content)
                    // resolve the row's geometry as one unit: otherwise each text and image animates its own
                    // frame when the row moves, and the titles trail behind the card.
                    .geometryGroup()
                    .transition(transition(k))
            }
        }
        .frame(width: LeagueTheme.moduleWidth * k)
        .environment(\.hudScale, k)
        .animation(spring, value: list)
        .animation(spring, value: content.suggestion?.next.id)
        .padding(OverlayLayout.shadowPadding * k)
        // flatten to one metal-rendered layer (including the shadow margin, so shadows and slides are not
        // clipped): otherwise every change, and every frame of a transition, re-rasterizes each text run and
        // gradient with coregraphics on the cpu.
        // the layer spans the whole panel, not the stack: while the stack grows, its animated bounds would
        // otherwise clip a row sliding in.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.alignment)
        .drawingGroup()
        .overlayPreferenceValue(CountdownSpots.self) { spots in
            GeometryReader { proxy in
                ForEach(spots, id: \.timer.token) { spot in
                    let r = proxy[spot.bounds]
                    CountdownBar(timer: spot.timer, color: spot.color, k: k)
                        .frame(width: max(r.width - 12 * k, 0), height: 2 * k)
                        .position(x: r.midX, y: r.maxY - 4 * k)
                        .transition(.opacity)
                }
            }
            .animation(spring, value: spots.map(\.timer.token))
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func row(_ module: Module, _ c: OverlayContent) -> some View {
        switch module {
        case .goal:
            if let goal = c.goal { GoalBadge(progress: goal) }
        case .nextBuy:
            if let s = c.suggestion {
                NextBuyCard(suggestion: s, iconURL: c.nextIconURL, thenIconURL: c.thenIconURL)
                    .alertCountdown(countdown(.nextBuy), color: LeagueTheme.gold)
            }
        case .augments:
            AugmentsCard(augments: c.augments)
        case .damage:
            if let ad = c.adShare { DamageMix(adShare: ad) }
        case .spike:
            if let spike = c.spike {
                SpikeRow(alert: spike)
                    .alertCountdown(countdown(.spike), color: LeagueTheme.red)
            }
        case .jungler:
            if let jungler = c.jungler {
                JunglerRow(status: jungler)
                    .alertCountdown(countdown(.jungler), color: LeagueTheme.muted)
            }
        case .previewTimer:
            if let end = state.previewEndsAt { PreviewTimer(end: end, total: OverlayController.previewDuration) }
        case .gold:
            if let gold = c.goldLead { GoldLeadCard(lead: gold) }
        }
    }

    /// the countdown line shows only while the row is up because of its alert; in the full hud it stays put.
    private func countdown(_ alert: OverlayAlert) -> AlertTimer? {
        state.full ? nil : state.alerts[alert]
    }

    /// rows slide in from the screen edge they are pinned to and fade; reduce motion keeps the fade only.
    private func transition(_ k: CGFloat) -> AnyTransition {
        if reduceMotion { return .opacity }
        let dx: CGFloat = state.alignment.horizontal == .leading ? -18 * k : state.alignment.horizontal == .center ? 0 : 18 * k
        let dy: CGFloat = state.alignment.horizontal == .center ? -8 * k : 0
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: dx, y: dy)),
                           removal: .opacity.combined(with: .offset(x: dx * 0.6, y: dy * 0.6)))
    }

    private var horizontal: HorizontalAlignment {
        switch state.alignment.horizontal {
        case .leading: .leading
        case .center: .center
        default: .trailing
        }
    }
}

/// a thin line along the bottom edge of an alert row that runs down until the alert disappears.
/// the run-down is a core animation on its own layer: animating it in swiftui redrew the whole hud (panels, shadows,
/// filters) every frame for the alert's lifetime.
private struct CountdownBar: View {
    let timer: AlertTimer
    let color: Color
    let k: CGFloat

    var body: some View {
        CountdownLine(timer: timer, color: NSColor(color.opacity(0.85)))
            .accessibilityHidden(true)
    }
}

private struct CountdownLine: NSViewRepresentable {
    let timer: AlertTimer
    let color: NSColor

    func makeNSView(context: Context) -> CountdownLineView { CountdownLineView() }

    func updateNSView(_ view: CountdownLineView, context: Context) {
        view.configure(start: timer.start, duration: timer.duration, color: color)
    }
}

final class CountdownLineView: NSView {
    private let bar = CALayer()
    private var start: Date?
    private var duration: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(start: Date, duration: TimeInterval, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.backgroundColor = color.cgColor
        CATransaction.commit()
        guard start != self.start || duration != self.duration else { return }
        self.start = start
        self.duration = duration
        restart()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(origin: .zero, size: bounds.size)
        bar.position = CGPoint(x: 0, y: bounds.midY)
        bar.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    /// runs from what is left (tab pressed and released mid-alert resumes, not restarts) down to empty.
    private func restart() {
        guard let start else { return }
        let remaining = max(start.addingTimeInterval(duration).timeIntervalSinceNow, 0)
        let from = duration > 0 ? remaining / duration : 0
        bar.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.transform = CATransform3DMakeScale(0, 1, 1)
        CATransaction.commit()
        guard remaining > 0 else { return }
        let run = CABasicAnimation(keyPath: "transform.scale.x")
        run.fromValue = from
        run.toValue = 0
        run.duration = remaining
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        bar.add(run, forKey: "countdown")
    }
}

/// where a row's countdown line goes. the lines are drawn outside the hud's `drawingGroup` (a native layer can't
/// render inside a flattened metal layer), so each row only reports its bounds and the line is placed over it.
struct CountdownSpot {
    let timer: AlertTimer
    let color: Color
    let bounds: Anchor<CGRect>
}

struct CountdownSpots: PreferenceKey {
    static let defaultValue: [CountdownSpot] = []
    static func reduce(value: inout [CountdownSpot], nextValue: () -> [CountdownSpot]) { value += nextValue() }
}

private extension View {
    func alertCountdown(_ timer: AlertTimer?, color: Color) -> some View {
        anchorPreference(key: CountdownSpots.self, value: .bounds) { anchor in
            timer.map { [CountdownSpot(timer: $0, color: color, bounds: anchor)] } ?? []
        }
    }
}

/// panel geometry shared by the view and the controller.
enum OverlayLayout {
    /// transparent margin around the modules so shadows and the spike slide are not clipped.
    static let shadowPadding: CGFloat = 14
    /// tallest stack (aram: next buy with two rows of chips, augments, damage, spike) at scale 1, plus slack.
    static let maxContentHeight: CGFloat = 520
    // calibrated on a real tab-scoreboard screenshot (16:10, game ~1330 px tall): kill feed ends at 0.27 x height,
    // the scoreboard is ~1.03 x height wide and centred, the respawn portraits over the minimap start at 0.60.
    /// top of the right-hand stack, as a share of the screen height from the top (below league's kill feed).
    static let upperTopFraction: CGFloat = 0.28
    /// the stack must end above league's respawn portraits.
    static let stackBottomFraction: CGFloat = 0.58
    /// the tab scoreboard's right edge, as a share of the screen height right of the screen centre.
    static let scoreboardHalfSpan: CGFloat = 0.52
    /// height of a typical full stack (goal, next buy, damage, jungler, gold) at scale 1, for fitting.
    static let typicalStackHeight: CGFloat = 310
    /// distance from the screen edges.
    static let margin: CGFloat = 16
}


/// "preview closes in 4s" with a thin bar that drains over the preview's length.
private struct PreviewTimer: View {
    let end: Date
    let total: Duration
    @Environment(\.hudScale) private var k

    var body: some View {
        let seconds = Double(total.components.seconds)
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let left = max(0, end.timeIntervalSince(context.date))
            VStack(spacing: 4 * k) {
                Text("Preview closes in \(Int(left.rounded(.up)))s")
                    .font(LeagueTheme.body(11 * k, .semibold))
                    .foregroundStyle(LeagueTheme.muted)
                    .monospacedDigit()
                Capsule().fill(LeagueTheme.navyDeep)
                    .frame(height: 3 * k)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(LeagueTheme.gold).frame(width: g.size.width * (left / seconds))
                        }
                    }
            }
            .padding(.horizontal, 10 * k)
            .padding(.vertical, 6 * k)
            .frame(maxWidth: .infinity)
            .leaguePanel(scale: k, shadow: false)
        }
    }
}
