import Foundation

public struct ItemRef: Sendable, Equatable, Hashable {
    public var id: Int
    public var name: String
    public var cost: Int

    public init(id: Int, name: String, cost: Int) {
        self.id = id; self.name = name; self.cost = cost
    }

    init(_ item: DDItem) { self.init(id: item.id, name: item.name, cost: item.goldTotal) }
}

public struct BuildSuggestion: Sendable, Equatable {
    public var next: ItemRef
    /// 1–3 short chips, e.g. "aatrox + soraka healing", "sion 130 armor". empty for plain base-build picks.
    public var reasons: [String]
    public var then: ItemRef?
    public var costRemaining: Int
    public var goldProgress: Double
    public var isCounter: Bool

    public init(next: ItemRef, reasons: [String], then: ItemRef?, costRemaining: Int, goldProgress: Double,
                isCounter: Bool) {
        self.next = next; self.reasons = reasons; self.then = then
        self.costRemaining = costRemaining; self.goldProgress = goldProgress; self.isCounter = isCounter
    }
}

extension BuildSuggestion {
    /// coarsened for the hud so it does not change on every 1 hz gold tick: cost rounds up to a multiple of 25
    /// (0 stays 0) and gold progress floors to 1/100.
    public func quantizedForDisplay() -> BuildSuggestion {
        var s = self
        s.costRemaining = costRemaining > 0 ? (costRemaining + 24) / 25 * 25 : costRemaining
        s.goldProgress = (goldProgress * 100).rounded(.down) / 100
        return s
    }
}
