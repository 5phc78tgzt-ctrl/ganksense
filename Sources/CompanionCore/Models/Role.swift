public enum Role: String, Codable, Sendable, CaseIterable {
    case top, jungle, mid, adc, support

    public init?(lcuPosition: String) {
        switch lcuPosition.lowercased() {
        case "top": self = .top
        case "jungle": self = .jungle
        case "middle": self = .mid
        case "bottom": self = .adc
        case "utility": self = .support
        default: return nil
        }
    }

    public init?(livePosition: String) {
        self.init(lcuPosition: livePosition)
    }
}
