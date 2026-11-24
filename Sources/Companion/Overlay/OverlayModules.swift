import SwiftUI
import AppKit
import CompanionCore

struct GoalBadge: View {
    let progress: GoalProgress

    /// compact titles so the live value never has to be truncated at 260 pt.
    static func shortTitle(_ g: Goal) -> String {
        let clock = "\(g.minutes ?? 0):00"
        return switch g.preset {
        case .deathsBefore14: "Deaths < \(clock)"
        case .csAt10: "CS @ \(clock)"
        case .csPerMinAt20: "By \(clock)"
        case .goldAt15: "Gold @ \(clock)"
        case .killParticipation: "Kill part."
        case .totalDeaths: "Deaths"
        }
    }
    @Environment(\.hudScale) private var k

    var body: some View {
        let color = Self.color(progress.state)
        HStack(alignment: .capCenter, spacing: 6 * k) {
            Diamond()
                .fill(color)
                .frame(width: 7 * k, height: 7 * k)
                .alignmentGuide(.capCenter) { d in d[VerticalAlignment.center] }
            Text(Self.shortTitle(progress.goal))
                .leagueLabel(scale: k, color: LeagueTheme.muted)
                .lineLimit(1)
                .capCentered(size: 10 * k, weight: .semibold)
            Spacer(minLength: 10 * k)
            HStack(alignment: .capCenter, spacing: 8 * k) {
                Text(progress.label)
                    .font(LeagueTheme.title(12 * k))
                    .tracking(-0.2 * k)
                    .monospacedDigit()
                    .foregroundStyle(LeagueTheme.text)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .capCentered(size: 12 * k, weight: .semibold)
                Text(Self.title(progress.state))
                    .leagueLabel(scale: k, color: color)
                    .lineLimit(1)
                    .fixedSize()
                    .capCentered(size: 10 * k, weight: .semibold)
            }
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 10 * k)
        .leaguePanel(scale: k)
        .accessibilityElement(children: .combine)
    }

    static func color(_ state: GoalState) -> Color {
        switch state {
        case .onTrack, .achieved: LeagueTheme.teal
        case .close: LeagueTheme.gold
        case .failed: LeagueTheme.red
        case .pending: LeagueTheme.muted
        }
    }

    static func title(_ state: GoalState) -> String {
        switch state {
        case .onTrack: "On track"
        case .close: "Close"
        case .failed: "Missed"
        case .achieved: "Done"
        case .pending: "Live"
        }
    }
}


struct NextBuyCard: View {
    let suggestion: BuildSuggestion
    let iconURL: URL?
    let thenIconURL: URL?
    @Environment(\.hudScale) private var k
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ready: Bool { suggestion.costRemaining <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * k) {
            HStack(alignment: .capCenter) {
                Text("Next buy").leagueLabel(scale: k, color: LeagueTheme.gold)
                    .capCentered(size: 10 * k, weight: .semibold)
                Spacer(minLength: 4 * k)
                if suggestion.isCounter {
                    Text("Counter").leagueLabel(scale: k, color: LeagueTheme.teal)
                        .capCentered(size: 10 * k, weight: .semibold)
                }
            }

            HStack(alignment: .center, spacing: 10 * k) {
                ItemIcon(url: iconURL, size: 36 * k, frameColor: ready ? LeagueTheme.teal : LeagueTheme.gold)
                VStack(alignment: .leading, spacing: 3 * k) {
                    Text(suggestion.next.name)
                        .font(LeagueTheme.title(14 * k))
                        .tracking(-0.2 * k)
                        .foregroundStyle(LeagueTheme.text)
                        .lineLimit(1)
                    HStack(alignment: .capCenter, spacing: 5 * k) {
                        GoldCoin().frame(width: 8 * k, height: 8 * k)
                            .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
                        Text(suggestion.next.cost.formatted())
                            .font(LeagueTheme.body(11.5 * k, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(LeagueTheme.gold)
                            .capCentered(size: 11.5 * k, weight: .semibold)
                        Text("·")
                            .font(LeagueTheme.body(11.5 * k, .regular))
                            .foregroundStyle(LeagueTheme.muted.opacity(0.6))
                            .capCentered(size: 11.5 * k, weight: .regular)
                        Text(ready ? "Ready to buy" : "\(suggestion.costRemaining.formatted()) to go")
                            .font(LeagueTheme.body(11.5 * k, ready ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(ready ? LeagueTheme.teal : LeagueTheme.muted)
                            .lineLimit(1)
                            .capCentered(size: 11.5 * k, weight: ready ? .semibold : .regular)
                    }
                }
                // center the text block on the cap-height span (top of name caps -> price baseline),
                // not on its line boxes, so it lines up with the icon's center.
                .alignmentGuide(VerticalAlignment.center) { [nameCap = NSFont.systemFont(ofSize: 14 * k, weight: .semibold).capHeight] d in
                    (d[.firstTextBaseline] - nameCap + d[.lastTextBaseline]) / 2
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GoldBar(progress: suggestion.goldProgress, ready: ready)
                .frame(height: 4 * k)

            if !suggestion.reasons.isEmpty {
                FlowLayout(spacing: 4 * k, lineSpacing: 4 * k) {
                    ForEach(Array(suggestion.reasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                        LeagueChip(text: reason, k: k)
                    }
                }
            }

            if let then = suggestion.then {
                LeagueRule().opacity(0.7)
                HStack(alignment: .capCenter, spacing: 7 * k) {
                    Text("Then").leagueLabel(scale: k)
                        .capCentered(size: 10 * k, weight: .semibold)
                    ItemIcon(url: thenIconURL, size: 18 * k, frameColor: LeagueTheme.bronze)
                        .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
                    Text(then.name)
                        .font(LeagueTheme.body(11.5 * k, .medium))
                        .foregroundStyle(LeagueTheme.text.opacity(0.85))
                        .lineLimit(1)
                        .capCentered(size: 11.5 * k, weight: .medium)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10 * k)
        .leaguePanel(scale: k)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next buy: \(suggestion.next.name)")
    }
}

/// howling abyss: the champion's best augments (op.gg), ranked; the tier is a small label on the right.
struct AugmentsCard: View {
    let augments: [AramAugment]
    @Environment(\.hudScale) private var k

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * k) {
            Text("Augments").leagueLabel(scale: k, color: LeagueTheme.gold)
                .capCentered(size: 10 * k, weight: .semibold)
            LeagueRule().opacity(0.7)
            VStack(alignment: .leading, spacing: 6 * k) {
                ForEach(Array(augments.enumerated()), id: \.element.id) { index, augment in
                    HStack(alignment: .capCenter, spacing: 8 * k) {
                        Text("\(index + 1)")
                            .font(LeagueTheme.body(11 * k, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(LeagueTheme.gold)
                            .frame(width: 10 * k, alignment: .leading)
                            .capCentered(size: 11 * k, weight: .semibold)
                        Text(augment.name)
                            .font(LeagueTheme.body(12 * k, .medium))
                            .foregroundStyle(LeagueTheme.text)
                            .lineLimit(1)
                            .capCentered(size: 12 * k, weight: .medium)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(10 * k)
        .leaguePanel(scale: k)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Best augments: " + augments.map(\.name).joined(separator: ", "))
    }
}

/// gold progress toward the next item: teal fill on a recessed navy track.
struct GoldBar: View {
    let progress: Double
    let ready: Bool

    var body: some View {
        GeometryReader { geo in
            let p = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(LeagueTheme.navyDeep)
                Rectangle()
                    .fill(LinearGradient(colors: [LeagueTheme.teal.opacity(0.75), LeagueTheme.teal],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * p)
                    .shadow(color: LeagueTheme.teal.opacity(ready ? 0.7 : 0), radius: 3)
            }
            .overlay(Rectangle().strokeBorder(LeagueTheme.bronze.opacity(0.8), lineWidth: 0.5))
        }
        .accessibilityHidden(true)
    }
}

struct GoldCoin: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(hex: 0xF0D48A), LeagueTheme.gold, LeagueTheme.bronze],
                                 center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
            .overlay(Circle().strokeBorder(LeagueTheme.bronze, lineWidth: 0.5))
    }
}


struct DamageMix: View {
    let adShare: Double
    @Environment(\.hudScale) private var k
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ad = min(max(adShare, 0), 1)
        let adPct = Int((ad * 100).rounded())
        // optical vertical balance: text line boxes add ascender space above the caps and descender space
        // below the baseline. measure both from the tallest/lowest text in the header (the 10.5 pt legend)
        // so the visible gaps are caps-top -> panel top = 8k, caps baseline -> bar top = 7k, bar -> panel bottom = 8k.
        let legendFont = NSFont.systemFont(ofSize: 10.5 * k, weight: .semibold)
        let aboveCaps = legendFont.ascender - legendFont.capHeight   // line box top -> cap top
        let belowBaseline = -legendFont.descender                    // baseline -> line box bottom
        VStack(alignment: .leading, spacing: 8 * k - belowBaseline) {
            HStack(alignment: .capCenter) {
                Text("Enemy damage").leagueLabel(scale: k).lineLimit(1)
                    .capCentered(size: 10 * k, weight: .semibold)
                Spacer(minLength: 10 * k)
                HStack(alignment: .capCenter, spacing: 10 * k) {
                    legend("AD", adPct, LeagueTheme.physical)
                    legend("AP", 100 - adPct, LeagueTheme.magic)
                }
            }
            GeometryReader { geo in
                let gap: CGFloat = 1.5 * k
                let w = max(geo.size.width - gap, 0)
                HStack(spacing: gap) {
                    Rectangle().fill(LeagueTheme.physical).frame(width: w * ad)
                    Rectangle().fill(LeagueTheme.magic)
                }
                .overlay(Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            }
            .frame(height: 5 * k)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1), value: ad)
        }
        .padding(.horizontal, 10 * k)
        .padding(.top, 10 * k - aboveCaps)
        .padding(.bottom, 10 * k)
        .leaguePanel(scale: k)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Enemy damage \(adPct) percent physical, \(100 - adPct) percent magic")
    }

    private func legend(_ title: String, _ pct: Int, _ color: Color) -> some View {
        HStack(alignment: .capCenter, spacing: 4 * k) {
            Rectangle().fill(color).frame(width: 6 * k, height: 6 * k)
                .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
            Text("\(title) \(pct)%")
                .font(LeagueTheme.body(10.5 * k, .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(LeagueTheme.text.opacity(0.9))
                .contentTransition(.numericText())
                .capCentered(size: 10.5 * k, weight: .semibold)
        }
    }
}


struct SpikeRow: View {
    let alert: SpikeAlert
    @Environment(\.hudScale) private var k

    var body: some View {
        HStack(alignment: .capCenter, spacing: 8 * k) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10 * k, weight: .bold))
                .foregroundStyle(LeagueTheme.red)
                .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
            // one line when it fits; otherwise champion over the spike (split at the " · "), never cut mid-name.
            ViewThatFits(in: .horizontal) {
                line(alert.text).fixedSize(horizontal: true, vertical: false)
                // the fallback may truncate: an unusually long item name still can't push the label off the card.
                VStack(alignment: .leading, spacing: 2 * k) {
                    line(head)
                    line(tail)
                }
            }
            .capCentered(size: 12 * k, weight: .semibold)
            Spacer(minLength: 10 * k)
            Text("Spike")
                .leagueLabel(scale: k, color: LeagueTheme.red)
                .capCentered(size: 10 * k, weight: .semibold)
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 10 * k)
        .background {
            LinearGradient(colors: [LeagueTheme.red.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: LeagueTheme.cornerRadius * k))
        }
        .leaguePanel(scale: k, accent: LeagueTheme.red)
        .accessibilityElement(children: .combine)
    }

    private var parts: [Substring] { alert.text.split(separator: " · ", maxSplits: 1) }
    private var head: String { parts.count == 2 ? String(parts[0]) : alert.text }
    private var tail: String { parts.count == 2 ? String(parts[1]) : "" }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(LeagueTheme.title(12 * k, .semibold))
            .tracking(-0.2 * k)
            .foregroundStyle(LeagueTheme.text)
            .lineLimit(1)
    }
}


/// informational only: a quiet single line, no accent, no label.
struct JunglerRow: View {
    let status: JunglerStatus
    @Environment(\.hudScale) private var k

    var body: some View {
        HStack(alignment: .capCenter, spacing: 6 * k) {
            Image(systemName: status.isDead ? "moon.zzz.fill" : "eye.fill")
                .font(.system(size: 9 * k, weight: .semibold))
                .foregroundStyle(LeagueTheme.muted)
                .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
            Text(status.headline)
                .font(LeagueTheme.body(10.5 * k, .medium))
                .foregroundStyle(LeagueTheme.muted)
                .lineLimit(1)
                .capCentered(size: 10.5 * k, weight: .medium)
            Spacer(minLength: 10 * k)
            // same small tracked caps as "close" / "spike", so the stack reads as one system.
            Text(status.detail)
                .leagueLabel(scale: k, color: LeagueTheme.muted)
                .lineLimit(1)
                .fixedSize()
                .capCentered(size: 10 * k, weight: .semibold)
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 10 * k)
        .leaguePanel(scale: k, accent: LeagueTheme.muted.opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}


struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}


/// item gold lead while tab is held: team, my lane and the per-role diffs. an estimate from items owned.
struct GoldLeadCard: View {
    let lead: GoldLead
    @Environment(\.hudScale) private var k

    /// "+1.2k" above 999, "+850" below, "Even" within 100 gold.
    static func text(_ diff: Int) -> String {
        if abs(diff) < 100 { return "Even" }
        let sign = diff > 0 ? "+" : "-"
        let n = abs(diff)
        return n < 1000 ? "\(sign)\(n)" : "\(sign)\(String(format: "%.1f", Double(n) / 1000))k"
    }

    static func color(_ diff: Int) -> Color {
        abs(diff) < 100 ? LeagueTheme.muted : diff > 0 ? LeagueTheme.teal : LeagueTheme.red
    }

    private static func short(_ role: Role) -> String {
        switch role {
        case .top: "TOP"
        case .jungle: "JNG"
        case .mid: "MID"
        case .adc: "BOT"
        case .support: "SUP"
        }
    }

    var body: some View {
        // title + team lead, then a compact column per role (my role's label is gold, which is the lane lead).
        VStack(alignment: .leading, spacing: 6 * k) {
            row("Item gold", "Team", lead.team)
            if lead.roles.count > 1 {
                HStack(spacing: 0) {
                    ForEach(lead.roles, id: \.role) { r in
                        VStack(spacing: 2 * k) {
                            Text(Self.short(r.role))
                                .leagueLabel(scale: k, color: r.isMe ? LeagueTheme.gold : LeagueTheme.muted)
                                .capCentered(size: 10 * k, weight: .semibold)
                            Text(Self.text(r.diff))
                                .font(LeagueTheme.body(11 * k, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Self.color(r.diff))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .capCentered(size: 11 * k, weight: .semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 8 * k)
        .leaguePanel(scale: k)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Item gold, team \(Self.text(lead.team))" + (lead.lane.map { ", lane \(Self.text($0))" } ?? ""))
    }

    private func row(_ title: String?, _ label: String, _ diff: Int) -> some View {
        HStack(alignment: .capCenter) {
            if let title {
                Text(title).leagueLabel(scale: k, color: LeagueTheme.gold)
                    .capCentered(size: 10 * k, weight: .semibold)
            }
            Spacer(minLength: 4 * k)
            Text(label).leagueLabel(scale: k)
                .capCentered(size: 10 * k, weight: .semibold)
            Text(Self.text(diff))
                .font(LeagueTheme.title(12 * k))
                .tracking(-0.2 * k)
                .monospacedDigit()
                .foregroundStyle(Self.color(diff))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .capCentered(size: 12 * k, weight: .semibold)
        }
    }
}
