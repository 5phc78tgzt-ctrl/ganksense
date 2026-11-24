import CoreGraphics

/// where the champ select banner goes, in appkit screen coordinates (origin bottom-left, y up).
public enum BannerPlacement {
    public enum Layout: Sendable { case full, slim }

    public static let gap: CGFloat = 6
    public static let fallbackWidth: CGFloat = 1024

    /// the full banner when it fits between the client and the menu bar (or the style says so), else the slim bar.
    public static func layout(style: BannerStyle, client: CGRect?, visible: CGRect, fullHeight: CGFloat) -> Layout {
        switch style {
        case .full: return .full
        case .slim: return .slim
        case .auto:
            guard let client else { return .full }
            return client.maxY + gap + fullHeight <= visible.maxY ? .full : .slim
        }
    }

    /// as wide as the client and right above it. when the space under the menu bar is too short (most laptops),
    /// it slides down over the client's top edge instead of leaving the screen. no client window: top center.
    public static func frame(client: CGRect?, visible: CGRect, height: CGFloat) -> CGRect {
        guard let client else {
            let width = min(fallbackWidth, visible.width)
            return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.maxY - gap - height).rounded(),
                          width: width, height: height)
        }
        let width = min(client.width, visible.width)
        let x = min(max(client.minX, visible.minX), visible.maxX - width)
        let y = min(client.maxY + gap, visible.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
    }
}
