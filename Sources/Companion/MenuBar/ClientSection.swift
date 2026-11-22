import SwiftUI
import CompanionCore

struct ClientSection: View {
    let model: AppModel

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            if let tilt = coordinator.tilt, tilt.reason != nil, let message = tilt.message {
                TiltCard(message: message)
                    .transition(.opacity)
            }

            GlassSection {
                GoalPicker(model: model)
            }

            if model.reviewHint != nil {
                GlassSection { ReviewLastGameRow(model: model) }
            }

            GlassSection { statsRows }
        }
    }

    private var statsRows: some View {
        VStack(spacing: 8) {
            if let result = coordinator.phase == .postGame ? coordinator.goalProgress : nil {
                StatRow(title: "Last game goal", value: Palette.title(for: result.state))
            }
            StatRow(title: "Today", value: todayText)
            if coordinator.goalStreak > 0 {
                StatRow(title: "Goal streak", value: "\(coordinator.goalStreak)")
            }
            if let line = deathInsight {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
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
        return "\(pct) % of recent deaths: likely \(top.key.phrase)"
    }
}

struct TiltCard: View {
    let message: String

    var body: some View {
        GlassSection(tint: Palette.amber) {
            HStack(alignment: .capCenter, spacing: 8) {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(Palette.amber)
                    .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .capCentered(style: .callout)
            }
        }
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
            Text("Goal for next game")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .popoverRow()
            HStack(alignment: .center, spacing: 8) {
                Text("Focus")
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 8)
                Picker("Goal for next game", selection: presetBinding) {
                    Text("No goal").tag(GoalPreset?.none)
                    Divider()
                    ForEach(GoalPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(GoalPreset?.some(preset))
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
    }

    private var presetBinding: Binding<GoalPreset?> {
        Binding(
            get: { coordinator.settings.goal?.preset },
            set: { preset in
                coordinator.setGoal(preset.map { Goal(preset: $0, target: coordinator.settings.target(for: $0)) })
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
