import Foundation

/// item gold lead: the total gold value of every item a player owns, my team minus the enemy team. the live api
/// only exposes my own current gold, so this is an item-value estimate, never exact gold earned.
public struct GoldLead: Sendable, Equatable {
    public struct RoleDiff: Sendable, Equatable {
        public var role: Role
        /// my team's player in this role minus the enemy's.
        public var diff: Int
        public var isMe: Bool

        public init(role: Role, diff: Int, isMe: Bool) { self.role = role; self.diff = diff; self.isMe = isMe }
    }

    public var team: Int
    /// me against my lane opponent; nil when positions are unknown or the map has no lanes.
    public var lane: Int?
    /// per-role diffs in lane order; empty when positions are unknown or the map has no lanes.
    public var roles: [RoleDiff]

    public init(team: Int, lane: Int?, roles: [RoleDiff]) { self.team = team; self.lane = lane; self.roles = roles }

    /// nil outside summoner's rift, the practice tool and howling abyss, or without a known team.
    public static func compute(snapshot s: LiveGameSnapshot, catalog: ItemCatalog?) -> GoldLead? {
        guard s.hasLiveFeatures, let me = s.me, me.team != .unknown, let catalog else { return nil }
        let mine = s.allPlayers.filter { $0.team == me.team }
        let theirs = s.enemies
        guard !theirs.isEmpty else { return nil }
        let team = mine.reduce(0) { $0 + itemGold($1, catalog) } - theirs.reduce(0) { $0 + itemGold($1, catalog) }
        guard !s.isHowlingAbyss else { return GoldLead(team: team, lane: nil, roles: []) }

        var roles: [RoleDiff] = []
        for role in Role.allCases {
            guard let a = only(mine, role), let b = only(theirs, role) else { continue }
            roles.append(RoleDiff(role: role, diff: itemGold(a, catalog) - itemGold(b, catalog), isMe: a == me))
        }
        return GoldLead(team: team, lane: roles.first { $0.isMe }?.diff, roles: roles)
    }

    /// owned items at full recipe value; consumables, wards and the trinket slot count as nothing.
    static func itemGold(_ p: Player, _ catalog: ItemCatalog) -> Int {
        p.items.reduce(0) { sum, it in
            guard it.slot != 6, let d = catalog.item(it.itemID),
                  !d.tags.contains("Consumable"), !d.tags.contains("Trinket"), !d.tags.contains("Vision")
            else { return sum }
            return sum + d.goldTotal * max(it.count, 1)
        }
    }

    private static func only(_ players: [Player], _ role: Role) -> Player? {
        let found = players.filter { $0.position.flatMap { Role(livePosition: $0) } == role }
        return found.count == 1 ? found[0] : nil
    }
}
