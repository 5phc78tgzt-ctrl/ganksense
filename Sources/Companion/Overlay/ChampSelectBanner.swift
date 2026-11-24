import SwiftUI
import AppKit
import CompanionCore

/// champ select banner: a league-style strip as wide as the client, right above it. runes with apply, the lane
/// matchup and ban ideas side by side; a column shows only when its data is there.
struct ChampSelectBanner: View {
    let model: AppModel
    /// the panel's width: the columns split it, so the banner keeps the client's width at any client size.
    let width: CGFloat
    /// the one-row bar layout for laptop screens, where the full banner would cover the client. the chevron opens the
    /// full banner (`model.bannerExpanded`).
    var slimLayout = false
    /// the shown panel only: how much of the banner is visible, from the top. the panel is sized to the larger of
    /// old and new height while this animates, so the bar opens and closes like a drawer instead of the window
    /// resizing (and the content crossfades). nil for the sizers, which measure the natural height.
    var reveal: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// the expanded state as the controller read it, so the measured height and the shown content always agree.
    var expanded: Bool? = nil

    private var isExpanded: Bool { expanded ?? model.bannerExpanded }
    private var slim: Bool { slimLayout && !isExpanded }
    private var canCollapse: Bool { slimLayout && isExpanded }

    private var advisor: ChampSelectAdvisor { model.coordinator.advisor }
    private var showsMatchupBuild: Bool { model.preferMatchupRunes && model.matchupRunes != nil }

    var body: some View {
        if let reveal {
            content
                .frame(height: reveal, alignment: .top)
                .clipped()
                .leaguePanel(shadow: false)
                .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.24), value: reveal)
                // fill the panel from the top; otherwise the hosting view centers a shorter root view.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        } else {
            content.leaguePanel(shadow: false)
        }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            if slim {
                SlimBanner(model: model, width: width).transition(.opacity)
            } else {
                full.transition(.opacity)
            }
        }
        .animation(reveal == nil || reduceMotion ? nil : .easeOut(duration: 0.16), value: slim)
        // one set of controls for both layouts, so expand, collapse and close never move.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if slim || canCollapse {
                    ExpandButton(expanded: !slim) { model.bannerExpanded = slim }
                }
                CloseButton { model.bannerDismissed = true }
            }
            .padding(.trailing, 4)
            .padding(.top, 8)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var full: some View {
        let runes = model.shownRunes
        let bans = advisor.banIdeas
        let record = model.personalRecord
        let warnings = advisor.teamWarnings
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                if let runes, let advice = advisor.advice {
                    RunesColumn(model: model, champion: advisor.adviceChampion, runes: runes, advice: advice,
                                core: showsMatchupBuild ? advisor.matchup?.coreItemIDs ?? [] : [],
                                coreNames: advisor.matchup?.coreItems ?? [])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)
                }
                if let tip = advisor.matchup {
                    if runes != nil { ColumnRule() }
                    MatchupColumn(tip: tip, mine: model.championIconURL(id: advisor.myChampionID),
                                  theirs: model.championIconURL(id: advisor.enemyID), inferred: advisor.enemyInferred)
                        .frame(minWidth: runes == nil ? nil : max(220, width * 0.26),
                               maxWidth: runes == nil ? .infinity : max(220, width * 0.26), alignment: .leading)
                        .layoutPriority(3)
                }
                if advisor.matchup == nil, runes != nil {
                    ColumnRule()
                    MatchupWaiting(opponent: advisor.enemyName)
                        .frame(minWidth: max(200, width * 0.22), maxWidth: max(200, width * 0.22), alignment: .leading)
                        .layoutPriority(3)
                }
                if !bans.isEmpty {
                    if runes != nil || advisor.matchup != nil { ColumnRule() }
                    BansColumn(model: model, champion: advisor.adviceChampion, picks: Array(bans.prefix(3)))
                        .fixedSize()
                }
            }
            if record != nil || !warnings.isEmpty {
                CompStrip(record: record, champion: advisor.adviceChampion, opponent: advisor.enemyName, warnings: warnings)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, canCollapse && bans.isEmpty ? 64 : 30)
        .padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

/// one row, about 46 pt: build icons with apply on the left, the lane matchup, my record and the team check on the
/// right. what doesn't fit is dropped (record text, then items); the chevron opens the full banner.
private struct SlimBanner: View {
    let model: AppModel
    let width: CGFloat

    private var advisor: ChampSelectAdvisor { model.coordinator.advisor }

    private var status: AppModel.RuneApplyStatus.State? {
        model.runeApply.flatMap { $0.page == model.shownRunes ? $0.state : nil }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let runes = model.shownRunes, let advice = advisor.advice {
                buildRow(runes: runes, advice: advice)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                trailing(record: true)
                trailing(record: false)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 64)
        .frame(width: width, height: 46, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }

    private func buildRow(runes: RunePage, advice: ChampionAdvice) -> some View {
        let icons = model.icons
        let core = model.preferMatchupRunes && model.matchupRunes != nil ? advisor.matchup?.coreItemIDs ?? [] : []
        return HStack(spacing: 4) {
            RuneGlyph(url: runes.primaryIDs.first.flatMap { icons?.runeURL(id: $0) }, size: 30, ring: LeagueTheme.gold)
                .help(runes.keystoneName ?? "")
            ForEach(Array(runes.primaryIDs.dropFirst().enumerated()), id: \.offset) { _, id in
                RuneGlyph(url: icons?.runeURL(id: id), size: 20, ring: LeagueTheme.bronze)
            }
            Divider2(height: 16)
            ForEach(Array(runes.secondaryIDs.enumerated()), id: \.offset) { _, id in
                RuneGlyph(url: icons?.runeURL(id: id), size: 20, ring: LeagueTheme.bronze)
            }
            Divider2(height: 16)
            ForEach(Array(advice.spellNames.enumerated()), id: \.offset) { _, name in
                ItemIcon(url: icons?.spellURL(name: name), size: 24, frameColor: LeagueTheme.bronze).help(name)
            }
            if !core.isEmpty {
                Divider2(height: 16)
                ForEach(Array(core.enumerated()), id: \.offset) { _, id in
                    ItemIcon(url: model.itemIconURL(id), size: 24, frameColor: LeagueTheme.gold)
                }
            }
            Button(status == .applied ? "Applied" : status == .applying ? "Applying…" : "Apply") { model.applyRunes() }
                .buttonStyle(SmallLeagueButtonStyle(done: status == .applied))
                .disabled(status == .applying)
                .padding(.leading, 6)
                .help("Writes this page to a rune page named \"\(RunePageApplier.pageName)\" and selects it")
        }
        .fixedSize()
        .layoutPriority(2)
    }

    private func trailing(record: Bool) -> some View {
        HStack(spacing: 10) {
            if let tip = advisor.matchup {
                HStack(spacing: 6) {
                    ItemIcon(url: model.championIconURL(id: advisor.enemyID), size: 24,
                             frameColor: tip.verdict == .unfavored ? LeagueTheme.gold : LeagueTheme.bronze)
                    Text(tip.verdictText)
                        .font(LeagueTheme.body(11, .semibold))
                        .foregroundStyle(tip.verdict == .favored ? LeagueTheme.teal : tip.verdict == .even ? LeagueTheme.muted : LeagueTheme.gold)
                        .lineLimit(1)
                }
                .help(tip.tip ?? tip.opponent)
            }
            if record, let r = model.personalRecord {
                Text(r.matchup.games > 0 ? "You \(r.champion.winRate)% · vs \(r.matchup.wins)–\(r.matchup.games - r.matchup.wins)"
                                          : "You \(r.champion.winRate)%")
                    .font(LeagueTheme.body(11))
                    .monospacedDigit()
                    .foregroundStyle(LeagueTheme.muted)
                    .lineLimit(1)
            }
            if let warning = advisor.teamWarnings.first {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    if record { Text(warning) }
                }
                .font(LeagueTheme.body(11, .semibold))
                .foregroundStyle(LeagueTheme.gold)
                .help("Team check: \(advisor.teamWarnings.joined(separator: ", ").lowercased())")
            }
        }
        .fixedSize()
    }
}

private struct ExpandButton: View {
    let expanded: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover ? LeagueTheme.text : LeagueTheme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(4)
        .help(expanded ? "Back to the slim bar" : "Show the full banner")
        .accessibilityLabel(expanded ? "Collapse champ select banner" : "Expand champ select banner")
    }
}

/// one line under the columns: my own results on this champion and into the lane opponent, and team comp warnings.
private struct CompStrip: View {
    let record: PersonalRecord?
    let champion: String?
    let opponent: String?
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(LeagueTheme.bronze.opacity(0.5)).frame(height: 1)
            HStack(spacing: 16) {
                if let record {
                    tally(label: champion.map { "You on \($0)" } ?? "You", record.champion, detail: "\(record.champion.games) games")
                    if record.matchup.games > 0, let opponent {
                        tally(label: "vs \(opponent)", record.matchup,
                              detail: "\(record.matchup.wins)–\(record.matchup.games - record.matchup.wins)")
                    }
                }
                Spacer(minLength: 8)
                ForEach(warnings, id: \.self) { warning in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                        Text(warning)
                    }
                    .font(LeagueTheme.body(11, .semibold))
                    .foregroundStyle(LeagueTheme.gold)
                    .help("Team check: \(warning.lowercased()) among the picks so far")
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func tally(label: String, _ tally: PersonalRecord.Tally, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(LeagueTheme.muted)
            Text("\(tally.winRate)%").monospacedDigit().fontWeight(.semibold)
                .foregroundStyle(tally.winRate >= 50 ? LeagueTheme.teal : LeagueTheme.text)
            Text(detail).monospacedDigit().foregroundStyle(LeagueTheme.muted)
        }
        .font(LeagueTheme.body(11))
    }
}

/// a thin bronze tick between icon groups.
private struct Divider2: View {
    var height: CGFloat = 18

    var body: some View {
        Rectangle().fill(LeagueTheme.bronze.opacity(0.6)).frame(width: 1, height: height).padding(.horizontal, 3)
    }
}

/// a rune or stat shard: its round art on a dark disc with a thin ring.
private struct RuneGlyph: View {
    let url: URL?
    let size: CGFloat
    let ring: Color
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(LeagueTheme.navyDeep)
            if let image = url.flatMap(ItemIconStore.cached) ?? image {
                Image(nsImage: image).resizable().interpolation(.high).padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(ring, lineWidth: 1))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ItemIconStore.cached(url) { image = hit; return }
            image = nil
            image = await ItemIconStore.load(url)
        }
        .accessibilityHidden(true)
    }
}

/// a short vertical bronze rule between columns.
private struct ColumnRule: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [LeagueTheme.bronze.opacity(0), LeagueTheme.bronze, LeagueTheme.bronze.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 1)
            .padding(.horizontal, 14)
    }
}

private struct ColumnHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .capCenter, spacing: 8) {
            Text(title).leagueLabel(color: LeagueTheme.gold)
                .lineLimit(1)
                .capCentered(size: 10, weight: .semibold)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 20)
    }
}

private struct RunesColumn: View {
    let model: AppModel
    let champion: String?
    let runes: RunePage
    let advice: ChampionAdvice
    /// matchup core item ids and names, shown only with the matchup page.
    let core: [Int]
    let coreNames: [String]

    private var status: AppModel.RuneApplyStatus.State? {
        model.runeApply.flatMap { $0.page == runes ? $0.state : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnHeader(title: champion.map { "Runes · \($0)" } ?? "Runes") {
                if let alt = model.matchupRunes, let opponent = model.coordinator.advisor.enemyName {
                    SourcePicker(matchup: Binding(get: { model.preferMatchupRunes }, set: { model.preferMatchupRunes = $0 }),
                                 opponent: opponent, games: alt.play)
                }
                if let note = Self.note(status) {
                    Text(note.text)
                        .font(LeagueTheme.body(11, .medium))
                        .foregroundStyle(note.color)
                        .lineLimit(1)
                        .help(note.help)
                        .capCentered(size: 11, weight: .medium)
                } else if runes.play > 0 {
                    Text("\(Self.percent(runes.winRate)) win · \(Self.percent(runes.pickRate)) pick")
                        .font(LeagueTheme.body(11))
                        .monospacedDigit()
                        .foregroundStyle(LeagueTheme.muted)
                        .lineLimit(1)
                        .capCentered(size: 11, weight: .regular)
                }
                Button(status == .applied ? "Applied" : status == .applying ? "Applying…" : "Apply") {
                    model.applyRunes()
                }
                .buttonStyle(SmallLeagueButtonStyle(done: status == .applied))
                .disabled(status == .applying)
                .help("Writes this page to a rune page named \"\(RunePageApplier.pageName)\" and selects it")
                .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
            }

            ViewThatFits(in: .horizontal) {
                build(shards: true, wide: true)
                build(shards: true, wide: false)
                build(shards: false, wide: false)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    /// the rune page on one side, spells, skill order and core items on the other; stacked when the column is narrow.
    private func build(shards: Bool, wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
        return layout {
            runeBlock(shards: shards)
            if wide { Divider2(height: 54) }
            pickBlock(skills: shards)
        }
    }

    private func runeBlock(shards: Bool) -> some View {
        let icons = model.icons
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                RuneGlyph(url: runes.primaryIDs.first.flatMap { icons?.runeURL(id: $0) }, size: 38, ring: LeagueTheme.gold)
                    .help(runes.keystoneName ?? "")
                ForEach(Array(runes.primaryIDs.dropFirst().enumerated()), id: \.offset) { i, id in
                    RuneGlyph(url: icons?.runeURL(id: id), size: 26, ring: LeagueTheme.bronze)
                        .help(runes.primaryNames.indices.contains(i + 1) ? runes.primaryNames[i + 1] : "")
                }
                Divider2()
                ForEach(Array(runes.secondaryIDs.enumerated()), id: \.offset) { i, id in
                    RuneGlyph(url: icons?.runeURL(id: id), size: 26, ring: LeagueTheme.bronze)
                        .help(runes.secondaryNames.indices.contains(i) ? runes.secondaryNames[i] : "")
                }
                if shards {
                    Divider2()
                    ForEach(Array(runes.shardIDs.enumerated()), id: \.offset) { i, id in
                        RuneGlyph(url: icons?.shardURL(id: id), size: 18, ring: LeagueTheme.bronze.opacity(0.6))
                            .help(runes.shardNames.indices.contains(i) ? runes.shardNames[i] : "")
                    }
                }
            }
            Text(runes.keystoneName ?? "")
                .font(LeagueTheme.body(11, .semibold))
                .foregroundStyle(LeagueTheme.gold)
                .lineLimit(1)
        }
    }

    private func pickBlock(skills: Bool) -> some View {
        let icons = model.icons
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(Array(advice.spellNames.enumerated()), id: \.offset) { _, name in
                    ItemIcon(url: icons?.spellURL(name: name), size: 30, frameColor: LeagueTheme.bronze).help(name)
                }
                if skills, !advice.skillMax.isEmpty {
                    Divider2()
                    Text("Max").font(LeagueTheme.body(11)).foregroundStyle(LeagueTheme.muted)
                    ForEach(Array(advice.skillMax.enumerated()), id: \.offset) { i, key in
                        if i > 0 { chevron }
                        Text(key)
                            .font(LeagueTheme.body(11, .bold))
                            .foregroundStyle(LeagueTheme.text)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 2).fill(LeagueTheme.navyDeep))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(LeagueTheme.bronze.opacity(0.7), lineWidth: 1))
                    }
                }
            }
            if !core.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(core.enumerated()), id: \.offset) { i, id in
                        if i > 0 { chevron }
                        ItemIcon(url: model.itemIconURL(id), size: 30, frameColor: LeagueTheme.gold)
                            .help(coreNames.indices.contains(i) ? coreNames[i] : "")
                    }
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(LeagueTheme.bronze)
    }

    private var runeLine: String {
        "\(runes.keystoneName ?? "") · \(runes.primaryStyleName) + \(runes.subStyleName)"
    }

    private var accessibilitySummary: String {
        var parts: [String] = [runeLine]
        parts.append("Shards " + runes.shardNames.joined(separator: ", "))
        parts.append("Spells " + advice.spellNames.joined(separator: ", "))
        if !core.isEmpty { parts.append("Core " + coreNames.joined(separator: ", ")) }
        if !advice.skillMax.isEmpty { parts.append("Max " + advice.skillMax.joined(separator: " then ")) }
        return parts.joined(separator: ". ")
    }

    private struct Note { let text: String; let color: Color; let help: String }

    private static func note(_ state: AppModel.RuneApplyStatus.State?) -> Note? {
        switch state {
        case .applied:
            Note(text: "Set as \"\(RunePageApplier.pageName)\"", color: LeagueTheme.teal,
                 help: "Written to the page \"\(RunePageApplier.pageName)\" and selected.")
        case .noFreeSlot:
            Note(text: "No free rune page", color: LeagueTheme.red,
                 help: "No free rune page slot. Free one in the client, then try again.")
        case .failed:
            Note(text: "Couldn't apply", color: LeagueTheme.red, help: "Couldn't apply. Is the League client open?")
        case .applying, nil: nil
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// standard page or the one for this lane opponent: two small tracked-caps chips.
private struct SourcePicker: View {
    @Binding var matchup: Bool
    let opponent: String
    let games: Int

    var body: some View {
        HStack(spacing: 2) {
            chip("Standard", on: !matchup) { matchup = false }
            chip("vs \(opponent)", on: matchup) { matchup = true }
                .help("The rune page most played into \(opponent), from \(games) games")
        }
        .fixedSize()
        .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LeagueTheme.body(10.5, .semibold))
                .foregroundStyle(on ? LeagueTheme.gold : LeagueTheme.muted)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(on ? LeagueTheme.gold.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// the matchup column before there is a tip: the lane opponent isn't known yet, or op.gg has nothing for the pair.
private struct MatchupWaiting: View {
    let opponent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnHeader(title: "Matchup") { EmptyView() }
            Text(opponent.map { "No tip for \($0) yet." } ?? "Your lane opponent isn't locked in. The matchup tip shows up as soon as they are.")
                .font(LeagueTheme.body(12))
                .foregroundStyle(LeagueTheme.muted)
                .lineSpacing(1.5)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MatchupColumn: View {
    let tip: MatchupTip
    let mine: URL?
    let theirs: URL?
    /// the opponent is a guess from their champion, not a known lane assignment.
    var inferred = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnHeader(title: inferred ? "Likely matchup" : "Matchup") {
                Text(tip.verdictText)
                    .font(LeagueTheme.body(11, .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .capCentered(size: 11, weight: .semibold)
            }
            HStack(spacing: 8) {
                ItemIcon(url: mine, size: 30, frameColor: tip.verdict == .favored ? LeagueTheme.teal : LeagueTheme.bronze)
                Text("vs").font(LeagueTheme.body(10.5, .semibold)).foregroundStyle(LeagueTheme.muted)
                ItemIcon(url: theirs, size: 30, frameColor: tip.verdict == .unfavored ? LeagueTheme.gold : LeagueTheme.bronze)
                Text(tip.opponent).font(LeagueTheme.body(12, .semibold)).foregroundStyle(LeagueTheme.text).lineLimit(1)
            }
            Text(tip.tip ?? "No tip for this lane yet.")
                .font(LeagueTheme.body(12))
                .foregroundStyle(tip.tip == nil ? LeagueTheme.muted : LeagueTheme.text.opacity(0.92))
                .lineSpacing(1.5)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(tip.tip ?? "")
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tip.verdict {
        case .favored: LeagueTheme.teal
        case .even: LeagueTheme.muted
        case .unfavored: LeagueTheme.gold
        }
    }
}

private struct BansColumn: View {
    let model: AppModel
    let champion: String?
    let picks: [CounterPick]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnHeader(title: "Ban ideas") { EmptyView() }
            HStack(alignment: .top, spacing: 10) {
                ForEach(picks, id: \.championKey) { pick in
                    VStack(spacing: 3) {
                        ItemIcon(url: model.championIconURL(key: pick.championKey), size: 36, frameColor: LeagueTheme.bronze)
                        Text(pick.name)
                            .font(LeagueTheme.body(11, .medium))
                            .foregroundStyle(LeagueTheme.text)
                            .lineLimit(1)
                        Text("\(Int((pick.winRate * 100).rounded()))% win")
                            .font(LeagueTheme.body(10))
                            .monospacedDigit()
                            .foregroundStyle(LeagueTheme.muted)
                    }
                    .frame(width: 58)
                }
            }
        }
        .help(champion.map { "Champions that do well against \($0)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ban ideas: \(picks.map(\.name).joined(separator: ", "))")
    }
}

/// the death review's league button at banner size: navy fill, gold hairline, small tracked caps; teal once done.
private struct SmallLeagueButtonStyle: ButtonStyle {
    var done = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, done: done, enabled: isEnabled)
    }

    struct Styled: View {
        let configuration: Configuration
        let done: Bool
        let enabled: Bool
        @State private var hover = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 2, style: .circular)
            let pressed = configuration.isPressed
            let edge = done ? LeagueTheme.teal : pressed ? LeagueTheme.bronze : hover ? Color(hex: 0xF0D9A0) : LeagueTheme.gold
            configuration.label
                .font(LeagueTheme.body(10.5, .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(done ? LeagueTheme.teal : LeagueTheme.text.opacity(enabled ? 1 : 0.6))
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(shape.fill(pressed ? LeagueTheme.navyDeep : hover ? Color(hex: 0x1E2D4A) : LeagueTheme.navy))
                .overlay(shape.strokeBorder(edge, lineWidth: 1))
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
                .onHover { hover = $0 }
                .contentShape(shape)
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover ? LeagueTheme.text : LeagueTheme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(4)
        .help("Hide until the next champ select")
        .accessibilityLabel("Hide champ select banner")
    }
}
