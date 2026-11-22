import SwiftUI
import AppKit
import CompanionCore

/// post-game death review in league's end-of-game look: victory / defeat header, the goal, then every death with
/// its likely cause (estimated from kill-feed and scoreboard data, read-only). always dark, whatever the system
/// appearance; the league language comes from `leaguetheme` (navy panel, gold hairline, parchment text).
struct DeathReviewView: View {
    let record: GameRecord
    var maxRows = DeathReviewView.scrollThreshold
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 440
    static let padding: CGFloat = 22
    /// vertical gap above and below every divider, and above the footer.
    static let gap: CGFloat = 16
    static let scrollThreshold = 5
    /// estimated height of one death row, for the scroll area.
    static let rowHeight: CGFloat = 112

    /// how many death rows fit before the list scrolls, for a screen with `available` points of height.
    static func rows(fitting available: CGFloat) -> Int {
        min(scrollThreshold, max(3, Int((available - 330) / rowHeight)))
    }

    private var analyses: [DeathAnalysis] { DeathAnalyzer.analyze(record) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            LeagueRule().padding(.vertical, Self.gap)
            goalSection
            LeagueRule().padding(.vertical, Self.gap)
            deathsSection
            footer.padding(.top, Self.gap)
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .leaguePanel(accent: accent, opacity: 0.97, shadow: false)
        .overlay(alignment: .topTrailing) { CloseButton(action: onDone).padding(10) }
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)
        .tint(LeagueTheme.gold)
    }


    private var header: some View {
        VStack(spacing: 6) {
            Text(resultTitle)
                .font(LeagueTheme.title(40, .bold))
                .tracking(1)
                .padding(.leading, 1) // tracking adds trailing space; balance it so the title is optically centred
                .foregroundStyle(resultColor)
                .lineLimit(1)
            Text("\(record.champion) · \(Self.clock(record.durationSec))")
                .leagueLabel(color: LeagueTheme.gold)
                .monospacedDigit()
                .padding(.leading, 0.6)
            if let summary = mostCommonCause {
                Text(summary)
                    .font(LeagueTheme.body(12))
                    .foregroundStyle(LeagueTheme.muted)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var resultTitle: String {
        switch record.win {
        case true?: "VICTORY"
        case false?: "DEFEAT"
        case nil: record.isVoid ? "REMAKE" : "GAME OVER"
        }
    }

    private var resultColor: Color {
        switch record.win {
        case true?: LeagueTheme.teal
        case false?: LeagueTheme.red
        case nil: LeagueTheme.text
        }
    }

    private var accent: Color {
        record.win == false ? LeagueTheme.red.opacity(0.85) : LeagueTheme.gold
    }

    /// "most common likely cause: teamfight (2 of 4 deaths)", only when one cause repeats.
    private var mostCommonCause: String? {
        var counts: [DeathCause: Int] = [:]
        for a in analyses where a.primary != .unclear { counts[a.primary, default: 0] += 1 }
        guard let top = counts.max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }), top.value >= 2
        else { return nil }
        return "Most common likely cause: \(top.key.phrase) (\(top.value) of \(record.deaths.count) deaths)"
    }


    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Goal").leagueLabel()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let goal = record.goalResult {
                    Text(goal.goal.preset.title)
                        .font(LeagueTheme.body(14, .medium))
                        .foregroundStyle(LeagueTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(goal.label)
                        .font(LeagueTheme.body(13))
                        .monospacedDigit()
                        .foregroundStyle(LeagueTheme.muted)
                    GoalStateTag(text: Self.outcome(goal.state), color: Self.color(for: goal.state))
                } else {
                    Text(record.isVoid ? "Remake: goal not counted" : "No goal this game")
                        .font(LeagueTheme.body(14))
                        .foregroundStyle(LeagueTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// past-tense wording for a finished game; "close" would read like a button here.
    static func outcome(_ state: GoalState) -> String {
        switch state {
        case .onTrack, .achieved: "Met"
        case .close: "Near miss"
        case .failed: "Missed"
        case .pending: "Not counted"
        }
    }

    static func color(for state: GoalState) -> Color { GoalBadge.color(state) }


    @ViewBuilder private var deathsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What happened?").leagueLabel()
                Spacer(minLength: 8)
                if !record.deaths.isEmpty {
                    Text("\(record.deaths.count) death\(record.deaths.count == 1 ? "" : "s")").leagueLabel()
                }
            }
            if record.deaths.isEmpty {
                Text("No deaths this game. Nothing to review.")
                    .font(LeagueTheme.body(14))
                    .foregroundStyle(LeagueTheme.muted)
                    .padding(.top, 11)
            } else if record.deaths.count > maxRows {
                LeagueScrollView { deathList }
                    .frame(height: CGFloat(maxRows) * Self.rowHeight)
                footnote
            } else {
                deathList
                footnote
            }
        }
    }

    private var deathList: some View {
        let items = Array(zip(record.deaths, analyses))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.0.id) { index, item in
                if index > 0 { LeagueRule() }
                DeathRow(death: item.0, analysis: item.1)
            }
        }
    }

    private var footnote: some View {
        Text("Likely causes are estimated from kill-feed and scoreboard data. Positions and vision aren't available, so treat them as hints.")
            .font(LeagueTheme.body(11))
            .foregroundStyle(LeagueTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 5)
    }


    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onDone) { Text("Done") }
                .buttonStyle(LeagueButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}


/// one death: time, "killed by x + assists", then the likely cause with its evidence and secondary factors.
private struct DeathRow: View {
    let death: DeathEvent
    let analysis: DeathAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DeathReviewView.clock(death.time))
                    .font(LeagueTheme.body(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LeagueTheme.gold)
                Text(killedBy)
                    .font(LeagueTheme.body(14))
                    .foregroundStyle(LeagueTheme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Likely cause").leagueLabel()
                    Text(analysis.title)
                        .font(LeagueTheme.body(14, .semibold))
                        .foregroundStyle(analysis.primary == .unclear ? LeagueTheme.muted : LeagueTheme.teal)
                }
                Text(analysis.evidence)
                    .font(LeagueTheme.body(12))
                    .foregroundStyle(LeagueTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !analysis.secondary.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(analysis.secondary, id: \.self) { cause in
                        LeagueChip(text: cause.chip, size: 11)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("At \(DeathReviewView.clock(death.time)). \(accessibilityText)")
    }

    private var accessibilityText: String {
        let extra = analysis.secondary.isEmpty ? "" : " Other factors: \(analysis.secondary.map(\.chip).joined(separator: ", "))."
        return "\(analysis.headline). \(analysis.evidence).\(extra)"
    }

    private var killedBy: AttributedString {
        var text = AttributedString("Killed by ")
        var killer = AttributedString(death.killer ?? "unknown")
        killer.font = LeagueTheme.body(14, .semibold)
        text.append(killer)
        if !death.assisters.isEmpty {
            var rest = AttributedString(" + \(death.assisters.joined(separator: ", "))")
            rest.foregroundColor = LeagueTheme.muted
            text.append(rest)
        }
        return text
    }
}

/// goal outcome as a coloured dot and word: plain status text, not a button-like tag.
private struct GoalStateTag: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(LeagueTheme.body(13, .semibold))
                .foregroundStyle(color)
        }
        .fixedSize()
    }
}

/// gold-outlined "x" in the panel's top-right corner.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(LeagueCloseStyle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
    }
}
