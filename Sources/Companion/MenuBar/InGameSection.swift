import SwiftUI
import CompanionCore

struct InGameSection: View {
    let model: AppModel

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            GlassSection {
                if let p = coordinator.goalProgress {
                    HStack(alignment: .capCenter) {
                        Text(p.goal.preset.title)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .capCentered(style: .caption1)
                        Spacer(minLength: 8)
                        Text(Palette.title(for: p.state))
                            .capCentered(style: .caption1, weight: .semibold)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.color(for: p.state))
                    }
                    Text(p.label)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else if coordinator.settings.goal == nil {
                    Text("No goal this game")
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                } else {
                    Text("Waiting for the game to start")
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            GlassSection {
                if let s = coordinator.suggestion {
                    SuggestionSummary(suggestion: s, iconURL: model.itemIconURL(s.next.id))
                } else {
                    Text(coordinator.snapshot == nil ? "Loading game data" : "No build suggestion yet")
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
}

private struct SuggestionSummary: View {
    let suggestion: BuildSuggestion
    let iconURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .capCenter) {
                Text("Next buy")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .capCentered(style: .caption1)
                Spacer(minLength: 8)
                Text(suggestion.costRemaining > 0 ? "\(Format.gold(suggestion.costRemaining)) to go" : "Ready")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(suggestion.costRemaining > 0 ? Color.primary.opacity(0.75) : Palette.teal)
                    .capCentered(style: .caption1, weight: .semibold)
            }
            HStack(spacing: 10) {
                PopoverItemIcon(url: iconURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.next.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let reason = suggestion.reasons.first {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            if let then = suggestion.then {
                Text("Then · \(then.name)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PopoverItemIcon: View {
    let url: URL?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                shape.fill(.quaternary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
