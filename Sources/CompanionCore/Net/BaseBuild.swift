import Foundation

public struct BaseBuild: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case opgg, template
    }

    public var champion: String
    public var role: Role
    public var starter: [Int]
    public var core: [Int]
    public var boots: Int?
    public var situational: [Int]
    public var source: Source
    public var patch: String

    public init(champion: String, role: Role, starter: [Int], core: [Int], boots: Int?,
                situational: [Int], source: Source, patch: String) {
        self.champion = champion
        self.role = role
        self.starter = starter
        self.core = core
        self.boots = boots
        self.situational = situational
        self.source = source
        self.patch = patch
    }
}
