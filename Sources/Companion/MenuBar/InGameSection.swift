import SwiftUI
import CompanionCore

struct InGameSection: View {
    let model: AppModel

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            if coordinator.snapshot?.isHowlingAbyss != true {
                GlassSection {
                    if let p = coordinator.goalProgress {
                        HStack(alignment: .capCenter) {
                            CardTitle(p.goal.title)
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

            if let tip = coordinator.advisor.matchup {
                GlassSection { MatchupContent(tip: tip) }
            }

            ScoutSection(model: model)
        }
    }
}

private struct SuggestionSummary: View {
    let suggestion: BuildSuggestion
    let iconURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .capCenter) {
                CardTitle("Next buy")
                Spacer(minLength: 8)
                Text(suggestion.costRemaining > 0 ? "\(Format.gold(suggestion.costRemaining)) to go" : "Ready")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(suggestion.costRemaining > 0 ? Color.primary.opacity(0.75) : Palette.accent)
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
    /// shared with the overlay's icons: disk + memory cache, so reopening the popover never re-downloads.
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if let image = url.flatMap(ItemIconStore.cached) ?? image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                shape.fill(.quaternary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(shape)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ItemIconStore.load(url)
        }
        .accessibilityHidden(true)
    }
}
