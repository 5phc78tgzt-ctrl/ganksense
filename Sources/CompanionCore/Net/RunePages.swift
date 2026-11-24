import Foundation

public enum RuneApplyOutcome: Equatable, Sendable {
    case applied, noFreeSlot, invalidPage, failed
}

/// writes a rune page into the client. only ever on the user's click.
public protocol RunePageWriter: Sendable {
    func applyRunePage(_ page: RunePage) async -> RuneApplyOutcome
}

/// a rune page as the client lists it (`/lol-perks/v1/pages`).
public struct PerkPage: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var isEditable: Bool
    public var isDeletable: Bool

    public init(id: Int, name: String, isEditable: Bool, isDeletable: Bool) {
        self.id = id
        self.name = name
        self.isEditable = isEditable
        self.isDeletable = isDeletable
    }

    /// a page of the player's own (preset and default pages are not editable and use no owned slot).
    var isOwned: Bool { isEditable && isDeletable }
}

/// body for POST `/lol-perks/v1/pages` and PUT `/lol-perks/v1/pages/{id}`.
public struct RunePagePayload: Equatable, Sendable, Encodable {
    public var name: String
    public var primaryStyleId: Int
    public var subStyleId: Int
    public var selectedPerkIds: [Int]
    public var current: Bool
}

public enum RunePagePlan: Equatable, Sendable {
    case update(id: Int)
    case create
    case noFreeSlot
}

/// the safety rules of Apply: one page named "ganksense", updated in place or created in a free slot,
/// never any other page touched and nothing ever deleted.
public enum RunePageApplier {
    public static let pageName = "ganksense"

    /// nil unless the page passes validation (4 + 2 + 3 ids).
    public static func payload(for page: RunePage) -> RunePagePayload? {
        guard page.isValid else { return nil }
        return RunePagePayload(name: pageName, primaryStyleId: page.primaryStyleID, subStyleId: page.subStyleID,
                               selectedPerkIds: page.perkIDs, current: true)
    }

    /// reuse our own page when it exists; else create one only while owned pages are below the slot count.
    /// an unknown slot count (inventory unreadable) counts as no free slot.
    public static func plan(pages: [PerkPage], ownedPageCount: Int?) -> RunePagePlan {
        if let own = pages.first(where: { $0.name == pageName && $0.isOwned }) { return .update(id: own.id) }
        guard let owned = ownedPageCount, pages.filter(\.isOwned).count < owned else { return .noFreeSlot }
        return .create
    }

    static func decodePages(_ data: Data) -> [PerkPage]? {
        struct Item: Decodable {
            var id: Int?
            var name: String?
            var isEditable: Bool?
            var isDeletable: Bool?
        }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        return items.compactMap { item in
            guard let id = item.id else { return nil }
            return PerkPage(id: id, name: item.name ?? "", isEditable: item.isEditable ?? false,
                            isDeletable: item.isDeletable ?? false)
        }
    }

    static func decodeOwnedCount(_ data: Data) -> Int? {
        struct Inventory: Decodable { var ownedPageCount: Int? }
        return (try? JSONDecoder().decode(Inventory.self, from: data))?.ownedPageCount
    }

    static func decodeID(_ data: Data) -> Int? {
        struct Created: Decodable { var id: Int? }
        return (try? JSONDecoder().decode(Created.self, from: data))?.id
    }
}
