import AppKit
import SwiftUI

/// league in-game hud language: deep navy panels at ~86 % opacity, a 1 pt gold hairline with a darker bronze
/// inner line, near-square corners, parchment text, teal for "do this" and red only for warnings. riot's fonts
/// are proprietary, so it uses the system font with tight title tracking and tracked small-caps labels.
enum LeagueTheme {
    static let navyDeep = Color(hex: 0x010A13)
    static let navy = Color(hex: 0x0A1428)
    static let gold = Color(hex: 0xC8AA6E)
    static let bronze = Color(hex: 0x785A28)
    static let text = Color(hex: 0xF0E6D2)
    static let muted = Color(hex: 0xA09B8C)
    static let teal = Color(hex: 0x0AC8B9)
    static let red = Color(hex: 0xE84057)
    static let physical = Color(hex: 0xD85A30)
    static let magic = Color(hex: 0x378ADD)

    static let panelOpacity = 0.86
    static let cornerRadius: CGFloat = 4
    /// overlay module width at scale 1.
    static let moduleWidth: CGFloat = 260

    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}


extension EnvironmentValues {
    /// overlay size multiplier (settings › overlay › size). every overlay dimension is multiplied by it, so text
    /// is laid out at its final size and stays crisp (no `scaleeffect`).
    var hudScale: CGFloat {
        get { self[HUDScaleKey.self] }
        set { self[HUDScaleKey.self] = newValue }
    }
}

private struct HUDScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}


extension VerticalAlignment {
    private enum CapCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    /// optical center of capital letters. align text of different sizes/weights (and shapes that use
    /// `d[verticalalignment.center]`) on it so rows don't drift with each font's ascender/descender space.
    static let capCenter = VerticalAlignment(CapCenter.self)
}

extension View {
    /// publishes `.capcenter` at half the cap height above the first baseline of a text set in
    /// `nsfont.systemfont(ofsize:weight:)`. pass the same (already `k`-scaled) size and weight the text uses.
    func capCentered(size: CGFloat, weight: NSFont.Weight) -> some View {
        let capHeight = NSFont.systemFont(ofSize: size, weight: weight).capHeight
        return alignmentGuide(.capCenter) { d in d[.firstTextBaseline] - capHeight / 2 }
    }
}


extension View {
    /// navy hud panel: vertical navy gradient, gold outer hairline, bronze inner line, 4 pt corners.
    func leaguePanel(scale k: CGFloat = 1, accent: Color = LeagueTheme.gold, opacity: Double = LeagueTheme.panelOpacity,
                     shadow: Bool = true) -> some View {
        modifier(LeaguePanel(k: k, accent: accent, opacity: opacity, shadow: shadow))
    }

    /// tracked small-caps label (10 pt, +0.6). pass sentence-case strings; the casing is applied here.
    func leagueLabel(scale k: CGFloat = 1, color: Color = LeagueTheme.muted) -> some View {
        self.font(LeagueTheme.body(10 * k, .semibold))
            .tracking(0.6 * k)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

private struct LeaguePanel: ViewModifier {
    let k: CGFloat
    let accent: Color
    let opacity: Double
    let shadow: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LeagueTheme.cornerRadius * k, style: .circular)
        let alpha = reduceTransparency ? max(opacity, 0.97) : opacity
        content
            .background {
                shape.fill(LinearGradient(colors: [LeagueTheme.navy.opacity(alpha), LeagueTheme.navyDeep.opacity(alpha)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(LeagueTheme.cornerRadius * k - 1, 1), style: .circular)
                    .strokeBorder(LeagueTheme.bronze.opacity(0.55), lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: 6 * k, y: 2 * k)
    }
}

/// thin gold rule used between sections inside a panel.
struct LeagueRule: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [LeagueTheme.bronze.opacity(0), LeagueTheme.bronze, LeagueTheme.bronze.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
    }
}

/// small bordered chip (reason chips, death tags). `selected` fills it teal.
struct LeagueChip: View {
    let text: String
    var selected = false
    var k: CGFloat = 1
    var size: CGFloat = 10.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2 * k, style: .circular)
        Text(text)
            .font(LeagueTheme.body(size * k, .medium))
            .lineLimit(1)
            .foregroundStyle(selected ? LeagueTheme.navyDeep : LeagueTheme.text.opacity(0.92))
            .padding(.horizontal, 6 * k)
            .padding(.vertical, 2.5 * k)
            .background(shape.fill(selected ? LeagueTheme.teal : LeagueTheme.bronze.opacity(0.16)))
            .overlay(shape.strokeBorder(selected ? LeagueTheme.teal : LeagueTheme.bronze.opacity(0.9), lineWidth: 1))
    }
}

/// left-to-right wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((i, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
