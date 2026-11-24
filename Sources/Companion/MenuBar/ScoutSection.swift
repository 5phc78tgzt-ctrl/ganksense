import SwiftUI
import CompanionCore

/// loading screen scout: both teams with champion, riot id, solo/duo rank and season record. a row opens to the
/// player's top champions (op.gg, fetched only then). shown from the loading screen to the end of the game.
struct ScoutSection: View {
    let model: AppModel

    @AppStorage("scoutExpanded") private var expanded = true
    @State private var openRow: String?

    private var coordinator: Coordinator { model.coordinator }

    var body: some View {
        if let board = coordinator.scout.board {
            GlassSection {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(alignment: .capCenter, spacing: 8) {
                        CardTitle("Scout")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.secondaryText)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scout, \(expanded ? "expanded" : "collapsed")")

                if expanded {
                    ForEach(board.teams) { team in
                        VStack(alignment: .leading, spacing: 4) {
                            if board.teams.count > 1 {
                                Text(team.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            ForEach(team.players) { player in
                                ScoutRow(model: model, player: player, isOpen: openRow == player.id) {
                                    toggle(player.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if openRow == id {
            openRow = nil
        } else {
            openRow = id
            coordinator.scoutLoadPool(playerID: id)
        }
    }
}

private struct ScoutRow: View {
    let model: AppModel
    let player: ScoutPlayer
    let isOpen: Bool
    let toggle: () -> Void

    private var coordinator: Coordinator { model.coordinator }

    private var champion: String {
        coordinator.championCatalog?.champion(key: player.championKey)?.name ?? "Champion"
    }

    private func partnerName(_ flag: ScoutFlag) -> String? {
        guard case .duo(let key) = flag else { return nil }
        return coordinator.championCatalog?.champion(key: key)?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(champion)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(player.isMe ? Palette.accent : Color.primary)
                            .lineLimit(1)
                        if player.isMe {
                            Text("You")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette.accent)
                        }
                        Spacer(minLength: 6)
                        Text(player.rank?.label ?? "Rank unknown")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(player.rank?.isRanked == true ? Color.primary : Palette.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(player.gameName.isEmpty ? "Hidden" : player.riotId)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let record = Self.record(player.rank) {
                            Text(record)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    if !player.flags.isEmpty {
                        Text(player.flags.map { $0.label(partner: partnerName($0)) }.joined(separator: " · "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .accessibilityLabel(player.flags.map { $0.detail(partner: partnerName($0)) }.joined(separator: ". "))
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(player.isMe ? Palette.accent.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides top champions" : "Shows top champions")

            if isOpen { pool }
        }
    }

    @ViewBuilder private var pool: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !coordinator.settings.useOPGG {
                note("Turn on OP.GG data in Settings to see champions.")
            } else {
                switch coordinator.scout.pools[player.id] {
                case .loaded(let list) where !list.isEmpty:
                    ForEach(list, id: \.name) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.name).font(.caption)
                            Spacer(minLength: 6)
                            Text("\(c.games) games · \(c.winRatePercent)% win")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                case .loaded: note("No ranked games this season.")
                case .unavailable: note("Couldn't load champions.")
                case .loading, nil: note("Loading…")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Palette.secondaryText)
    }

    private static func record(_ rank: ScoutRank?) -> String? {
        guard let rank, let pct = rank.winRatePercent else { return nil }
        return "\(rank.wins)W \(rank.losses)L · \(pct)%"
    }
}
