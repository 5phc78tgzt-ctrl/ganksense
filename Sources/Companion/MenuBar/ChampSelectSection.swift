import SwiftUI
import CompanionCore

/// champ select in the popover: the advice itself lives in the banner above the client. once that banner is
/// closed, this row brings it back.
struct ChampSelectRow: View {
    let model: AppModel

    var body: some View {
        Button {
            model.bannerDismissed = false
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Champ select").font(.callout.weight(.medium))
                    Text("Runes, matchup and ban ideas")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 8)
                Text("Show")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the champ select banner")
    }
}

/// one-line verdict and the op.gg tip; shared by champ select and the in-game section.
struct MatchupContent: View {
    let tip: MatchupTip

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// about three lines at this width; longer tips get a more/less toggle.
    private var long: Bool { (tip.tip?.count ?? 0) > 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .capCenter, spacing: 6) {
                CardTitle("Matchup")
                Spacer(minLength: 8)
                Text(tip.verdictText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .capCentered(style: .caption1, weight: .semibold)
            }
            if let text = tip.tip {
                Text(text)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(expanded ? "Less" : "More") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tip.verdict {
        case .favored: Palette.accent
        case .even: Palette.secondaryText
        case .unfavored: Palette.amber
        }
    }
}
