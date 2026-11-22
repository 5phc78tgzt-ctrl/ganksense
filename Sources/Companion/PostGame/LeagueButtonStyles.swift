import SwiftUI

struct LeagueCloseStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .circular)
        configuration.label
            .foregroundStyle(configuration.isPressed || hovering ? LeagueTheme.text : LeagueTheme.gold)
            .background(shape.fill(configuration.isPressed ? LeagueTheme.gold.opacity(0.28) : LeagueTheme.gold.opacity(hovering ? 0.14 : 0)))
            .overlay(shape.strokeBorder(LeagueTheme.gold.opacity(hovering || configuration.isPressed ? 1 : 0.7),
                                        lineWidth: contrast == .increased ? 1.5 : 1))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .transaction { if configuration.isPressed { $0.animation = nil } }
    }
}

/// league primary button: navy fill, gold outline, parchment text; brighter on hover, darker on press (the press
/// state has no animation, so feedback is instant).
struct LeagueButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LeagueTheme.cornerRadius, style: .circular)
        let pressed = configuration.isPressed
        configuration.label
            .font(LeagueTheme.body(13, .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(pressed ? LeagueTheme.text.opacity(0.85) : LeagueTheme.text)
            .padding(.leading, 0.8) // balance the trailing tracking space
            .padding(.horizontal, 26)
            .padding(.top, 8.5) // all-caps has no descenders; nudge down to centre the caps vertically
            .padding(.bottom, 7.5)
            .frame(minWidth: 96)
            .background(shape.fill(pressed ? LeagueTheme.navyDeep : hovering ? Color(hex: 0x1E2D4A) : LeagueTheme.navy))
            .overlay(shape.strokeBorder(pressed ? LeagueTheme.bronze : hovering ? Color(hex: 0xF0D9A0) : LeagueTheme.gold,
                                        lineWidth: contrast == .increased ? 2 : 1))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .transaction { if pressed { $0.animation = nil } }
    }
}
