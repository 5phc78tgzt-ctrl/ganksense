import SwiftUI
import AppKit

/// swiftui's `.scrollindicators(.hidden)` doesn't always remove the appkit scroller (it can persist with a
/// mouse or "always show scroll bars"), so switch it off on the backing nsscrollview directly.
private struct SystemScrollerHider: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hide() }
        override func layout() { super.layout(); hide() }
        func hide() {
            var node: NSView? = self
            while let v = node {
                if let scroll = v as? NSScrollView {
                    scroll.hasVerticalScroller = false
                    scroll.hasHorizontalScroller = false
                    scroll.verticalScroller?.isHidden = true
                    return
                }
                node = v.superview
            }
            // the probe may sit beside the scroll view rather than inside it: sweep the window.
            func sweep(_ v: NSView) {
                if let scroll = v as? NSScrollView {
                    scroll.hasVerticalScroller = false
                    scroll.hasHorizontalScroller = false
                }
                v.subviews.forEach(sweep)
            }
            if let root = window?.contentView { sweep(root) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { DispatchQueue.main.async { view.hide() } }
}

/// scroll view with a thin gold league-style indicator in place of the system scroller.
struct LeagueScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 1
    @State private var viewHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            content.padding(.trailing, 12)
                .background(SystemScrollerHider())
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentOffset.y, g.contentSize.height, g.containerSize.height]
        } action: { _, v in
            offset = v[0]; contentHeight = max(v[1], 1); viewHeight = max(v[2], 1)
        }
        .overlay(alignment: .topTrailing) {
            let ratio = min(viewHeight / contentHeight, 1)
            let inset: CGFloat = 10
            let track = max(viewHeight - inset * 2, 1)
            let thumb = max(track * ratio, 24)
            let travel = max(track - thumb, 0)
            let maxOffset = max(contentHeight - viewHeight, 1)
            let y = travel * min(max(offset / maxOffset, 0), 1)
            ZStack(alignment: .top) {
                Capsule().fill(LeagueTheme.bronze.opacity(0.25)).frame(width: 3)
                Capsule().fill(LeagueTheme.gold.opacity(0.85)).frame(width: 3, height: thumb).offset(y: y)
            }
            .frame(width: 3, height: track)
            .padding(.vertical, inset)
            .opacity(ratio < 1 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
