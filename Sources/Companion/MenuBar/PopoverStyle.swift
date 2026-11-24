import SwiftUI
import AppKit
import CompanionCore

enum PopoverMetrics {
    static let row: CGFloat = 22
}

extension View {
    /// centres the row on the capital letters of a text-style font (same idea as the overlay's helper).
    func capCentered(style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> some View {
        let base = NSFont.preferredFont(forTextStyle: style)
        let font = weight.map { NSFont.systemFont(ofSize: base.pointSize, weight: $0) } ?? base
        let cap = font.capHeight
        return alignmentGuide(.capCenter) { d in d[.firstTextBaseline] - cap / 2 }
    }

    func popoverRow() -> some View {
        frame(minHeight: PopoverMetrics.row)
    }
}

enum Palette {
    /// secondary text on glass: the system .secondary is too faint over translucent materials.
    static let secondaryText = Color.primary.opacity(0.72)

    /// azure accent, shared with the website (#3b9eff).
    static let accent = Color(red: 0x3B / 255, green: 0x9E / 255, blue: 0xFF / 255)
    static let amber = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x3B / 255)

    static func color(for state: GoalState) -> Color {
        switch state {
        case .onTrack, .achieved: accent
        case .close: amber
        case .failed: .red
        case .pending: .secondary
        }
    }

    static func title(for state: GoalState) -> String {
        switch state {
        case .onTrack: "On track"
        case .close: "Close"
        case .failed: "Missed"
        case .achieved: "Done"
        case .pending: "In progress"
        }
    }
}

enum Format {
    static func record(wins: Int, losses: Int) -> String { "\(wins)W \(losses)L" }

    /// goal target in the preset's unit (kill participation stored as a fraction).
    static func target(_ value: Double, _ preset: GoalPreset) -> String {
        switch preset {
        case .killParticipation: "\(Int((value * 100).rounded()))%"
        case .csPerMinAt20: String(format: "%.1f CS/min", value)
        case .goldAt15: "\(Int(value).formatted()) gold"
        default: "\(Int(value.rounded())) \(preset.unit)"
        }
    }

    static func gold(_ value: Int) -> String { value.formatted() }

    static func streak(_ games: Int) -> String {
        switch games {
        case 0: "None yet"
        case 1: "1 game"
        default: "\(games) games"
        }
    }
}
