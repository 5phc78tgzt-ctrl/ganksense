import SwiftUI
import CompanionCore

struct ClientSection: View {
    let model: AppModel

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            if let tilt = coordinator.tilt, tilt.reason != nil, let message = tilt.message {
                TiltRow(message: message)
                    .transition(.opacity)
            }

            if model.inChampSelect, model.bannerDismissed {
                GlassSection { ChampSelectRow(model: model) }
            }

            GlassSection {
                GoalPicker(model: model)
            }

            GlassSection { recent }

            if let patterns = coordinator.patterns {
                GlassSection { PatternsCard(patterns: patterns, currentGoal: coordinator.settings.goal?.preset) }
            }
        }
    }

    /// today's record, the goal streak and the last game's review in one card.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle("Recent").popoverRow()
            if let result = coordinator.phase == .postGame ? coordinator.goalProgress : nil {
                StatRow(title: "Last game goal", value: Palette.title(for: result.state))
            }
            StatRow(title: "Today", value: todayText)
            StatRow(title: "Goal streak", value: Format.streak(coordinator.goalStreak))
            if coordinator.patterns == nil, let line = deathInsight {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.reviewHint != nil {
                Divider().padding(.vertical, 2)
                ReviewLastGameRow(model: model)
            }
        }
    }

    private var todayText: String {
        guard let t = coordinator.tilt else { return "No games yet" }
        if t.todayWins + t.todayLosses == 0 { return "No games yet" }
        return Format.record(wins: t.todayWins, losses: t.todayLosses)
    }

    private static let minDeathsForInsight = 5

    private var deathInsight: String? {
        let stats = coordinator.deathCauseStats
        let total = stats.values.reduce(0, +)
        let known = stats.filter { $0.key != .unclear }
        guard total >= Self.minDeathsForInsight, let top = known.max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) })
        else { return nil }
        let pct = Int((Double(top.value) / Double(total) * 100).rounded())
        return "\(pct)% of recent deaths: likely \(top.key.phrase)"
    }
}

/// tilt guard's nudge: one slim amber row above the cards, not a card of its own.
struct TiltRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.callout)
                .foregroundStyle(Palette.amber)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// goal for the next game: a preset menu plus a target stepper. the one goal control, shown in every popover
/// state that isn't a game; picking writes straight to settings, which the coordinator and overlay use.
struct GoalPicker: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        let goal = coordinator.settings.effectiveGoal()
        VStack(alignment: .leading, spacing: 6) {
            CardTitle("Goal for next game")
                .popoverRow()
            HStack(alignment: .center, spacing: 8) {
                Text("Focus")
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 8)
                Picker("Goal for next game", selection: presetBinding) {
                    Text("No goal").tag(GoalPreset?.none)
                    Divider()
                    ForEach(GoalPreset.allCases, id: \.self) { preset in
                        Text(coordinator.settings.title(for: preset)).tag(GoalPreset?.some(preset))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .font(.callout)
            .popoverRow()

            if let goal {
                HStack(alignment: .center, spacing: 8) {
                    Text(goal.preset.lowerIsBetter ? "At most" : "At least")
                        .foregroundStyle(Palette.secondaryText)
                    Spacer(minLength: 8)
                    Text(GoalTargetText.text(goal.target, goal.preset))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: goal.target))
                    Stepper("Target", value: targetBinding(goal), in: Self.range(goal.preset),
                            step: Self.step(goal.preset))
                        .labelsHidden()
                }
                .font(.callout)
                .popoverRow()
                .transition(.opacity)
                if let minutes = goal.minutes {
                    HStack(alignment: .center, spacing: 8) {
                        Text(goal.preset == .deathsBefore14 ? "Counted until" : "Checked at")
                            .foregroundStyle(Palette.secondaryText)
                        Spacer(minLength: 8)
                        Text("\(minutes):00")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(minutes)))
                        Stepper("Minute", value: minutesBinding(goal), in: Self.minutesRange, step: 1)
                            .labelsHidden()
                    }
                    .font(.callout)
                    .popoverRow()
                    .transition(.opacity)
                }
            } else {
                Text("Pick one thing to focus on.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
                    .popoverRow()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: goal?.preset)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: goal?.target)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: goal?.minutes)
    }

    private var presetBinding: Binding<GoalPreset?> {
        Binding(
            get: { coordinator.settings.goal?.preset },
            set: { preset in
                coordinator.setGoal(preset.map {
                    Goal(preset: $0, target: coordinator.settings.target(for: $0), minutes: coordinator.settings.minutes(for: $0))
                })
            }
        )
    }

    /// writes the preset's global target (and the goal's), so the game uses exactly what the stepper shows.
    private func targetBinding(_ goal: Goal) -> Binding<Double> {
        Binding(
            get: { goal.target },
            set: { value in
                var s = coordinator.settings
                s.setTarget(value, for: goal.preset)
                coordinator.updateSettings(s)
            }
        )
    }

    private func minutesBinding(_ goal: Goal) -> Binding<Double> {
        Binding(
            get: { Double(goal.minutes ?? 0) },
            set: { value in
                var s = coordinator.settings
                s.setMinutes(Int(value.rounded()), for: goal.preset)
                coordinator.updateSettings(s)
            }
        )
    }

    static let minutesRange: ClosedRange<Double> = Double(GoalPreset.minutesRange.lowerBound)...Double(GoalPreset.minutesRange.upperBound)

    static func step(_ preset: GoalPreset) -> Double {
        switch preset {
        case .deathsBefore14, .totalDeaths: 1
        case .csAt10: 5
        case .csPerMinAt20: 0.5
        case .killParticipation: 0.05
        case .goldAt15: 250
        }
    }

    static func range(_ preset: GoalPreset) -> ClosedRange<Double> {
        switch preset {
        case .deathsBefore14: 0...10
        case .totalDeaths: 0...15
        case .csAt10: 0...120
        case .csPerMinAt20: 0...12
        case .killParticipation: 0.1...1
        case .goldAt15: 1000...10000
        }
    }
}

enum GoalTargetText {
    static func text(_ value: Double, _ preset: GoalPreset) -> String {
        if preset.lowerIsBetter { return Int(value.rounded()) == 1 ? "1 death" : "\(Int(value.rounded())) deaths" }
        return Format.target(value, preset)
    }
}

/// "your last 10 games": collapsed to the most common likely cause, expanded to the early-death, killer and goal
/// figures plus one suggestion. causes are estimates, so the wording stays soft.
struct PatternsCard: View {
    let patterns: GamePatterns
    let currentGoal: GoalPreset?

    @AppStorage("patternsCardExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your last \(patterns.games) games")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.secondaryText)
                        if !expanded {
                            Text(patterns.causeLine ?? patterns.earlyLine)
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your last \(patterns.games) games")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides the patterns")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let line = patterns.causeLine { Text(line) }
                    Text(patterns.earlyLine).monospacedDigit()
                    if let line = patterns.trendLine { Text(line).monospacedDigit() }
                    if let line = patterns.killerLine { Text(line) }
                    if let goals = patterns.goals { goalRecord(goals) }
                    if let s = patterns.suggestion, s.preset != currentGoal {
                        Text(s.text)
                            .foregroundStyle(Palette.accent)
                            .padding(.top, 2)
                    }
                    Text("Causes are estimates from the kill feed and scoreboard.")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.top, 2)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
    }

    private func goalRecord(_ g: GamePatterns.GoalRecord) -> some View {
        Text("Goals: \(g.met) met, \(g.nearMiss) near miss, \(g.missed) missed")
            .monospacedDigit()
    }
}
