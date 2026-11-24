import AppKit
import SwiftUI
import Observation
import CompanionCore

/// shows `champselectbanner` in a non-activating panel above the league client while champ select runs, it has
/// advice to show, it wasn't closed, and the client (or this app) is in front. the client's window is looked up
/// once a second, only during champ select (owner pid and bounds only, never titles or contents).
@MainActor
final class ChampSelectBannerController {
    private let model: AppModel
    /// preview: a stand-in client rect (appkit coordinates), and no front-app check.
    private let previewClient: CGRect?
    private let panel = BannerPanel()
    private let host: BannerHostingView
    /// measures the banner's height for a width; the shown host has no sizing options, so its fittingsize is zero.
    private let sizer: NSHostingView<ChampSelectBanner>
    /// measures the full banner whatever is shown, to decide whether it fits above the client.
    private let fullSizer: NSHostingView<ChampSelectBanner>
    private var trackTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var wasInChampSelect = false
    private var shown = false
    private var loggedClient: CGRect?

    init(model: AppModel, previewClient: CGRect? = nil) {
        self.model = model
        self.previewClient = previewClient
        host = BannerHostingView(rootView: ChampSelectBanner(model: model, width: BannerPlacement.fallbackWidth))
        host.sizingOptions = []
        sizer = NSHostingView(rootView: ChampSelectBanner(model: model, width: BannerPlacement.fallbackWidth))
        fullSizer = NSHostingView(rootView: ChampSelectBanner(model: model, width: BannerPlacement.fallbackWidth))
        host.safeAreaRegions = []
        // a plain container, like the overlay: as the content view itself the hosting view can feed its size back
        // into the window's constraints and loop.
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
    }

    func start() { observe() }

    func stop() {
        trackTask?.cancel()
        trackTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel.orderOut(nil)
    }

    private func observe() {
        let advisor = model.coordinator.advisor
        let (inChampSelect, hasContent, dismissed, _, realChampSelect) = withObservationTracking {
            (model.inChampSelect,
             advisor.advice?.runes != nil || advisor.matchup != nil || !advisor.banIdeas.isEmpty,
             model.bannerDismissed,
             model.bannerExpanded,
             model.coordinator.phase == .client(.champSelect))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        // the settings demo ends when it's closed or a real champ select starts (not in the preview process).
        if previewClient == nil, model.champSelectPreview, dismissed || realChampSelect {
            model.endBannerDemo()
            return
        }
        if inChampSelect, !wasInChampSelect, dismissed {
            wasInChampSelect = true
            model.bannerDismissed = false
            model.preferMatchupRunes = true
            model.bannerExpanded = false
            return
        }
        if inChampSelect, !wasInChampSelect { model.preferMatchupRunes = true; model.bannerExpanded = false }
        wasInChampSelect = inChampSelect
        if inChampSelect, hasContent, !dismissed { startTracking() } else { stopTracking() }
    }

    private func startTracking() {
        model.loadIcons()
        guard trackTask == nil else { update(); return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTracking() {
        trackTask?.cancel()
        trackTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        hide()
    }

    private func update() {
        model.loadIcons()
        guard previewClient != nil || Self.clientOrSelfInFront() else { hide(); return }
        let client = previewClient ?? ClientWindow.frame() ?? (model.champSelectPreview ? Self.standInClient() : nil)
        if previewClient == nil, client != loggedClient {
            loggedClient = client
            AppLog.app.notice("Champ select banner: client window \(client.map { "\(Int($0.width))x\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" } ?? "not found", privacy: .public)")
        }
        let screen = client.flatMap(Self.screen(containing:)) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(client?.width ?? BannerPlacement.fallbackWidth, visible.width)
        fullSizer.rootView = ChampSelectBanner(model: model, width: width)
        let layout = BannerPlacement.layout(style: model.coordinator.settings.bannerStyle, client: client, visible: visible,
                                            fullHeight: ceil(fullSizer.fittingSize.height))
        let slimLayout = layout == .slim
        let expanded = model.bannerExpanded
        sizer.rootView = ChampSelectBanner(model: model, width: width, slimLayout: slimLayout, expanded: expanded)
        let height = ceil(sizer.fittingSize.height)
        var frame = BannerPlacement.frame(client: client, visible: visible, height: height)
        if slimLayout, expanded {
            // opened from the slim bar: keep its top edge where it was and grow downward over the client.
            let top = BannerPlacement.frame(client: client, visible: visible, height: 46).maxY
            frame.origin.y = top - height
        }
        let reveal = { (h: CGFloat) in
            self.host.rootView = ChampSelectBanner(model: self.model, width: width, slimLayout: slimLayout, reveal: h, expanded: expanded)
        }
        if shown, panel.frame.width == frame.width, panel.frame.maxY == frame.maxY, panel.frame.height != frame.height {
            // same top edge, new height (bar <-> full): the content animates its reveal; the panel takes the larger
            // size first and shrinks once a close has played out.
            shrinkTask?.cancel()
            if frame.height > panel.frame.height {
                panel.setFrame(frame, display: true)
                reveal(frame.height)
            } else {
                reveal(frame.height)
                let target = frame
                let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.26
                shrinkTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.panel.setFrame(target, display: true)
                    self.shrinkTask = nil
                }
            }
        } else if shrinkTask == nil || panel.frame.maxY != frame.maxY || panel.frame.width != frame.width {
            shrinkTask?.cancel()
            shrinkTask = nil
            reveal(frame.height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        show()
    }

    private func show() {
        guard !shown else { return }
        shown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        panel.orderOut(nil)
    }

    private static func clientOrSelfInFront() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return LeagueProcessWatcher.kind(bundleID: app.bundleIdentifier,
                                         executable: app.executableURL?.lastPathComponent) == .client
    }

    /// the demo without league open: a default size client (1280x720, smaller on small screens) centered on the
    /// main screen, so the banner shows the layout this screen would get.
    private static func standInClient() -> CGRect? {
        guard let visible = NSScreen.main?.visibleFrame else { return nil }
        let width = min(1280, visible.width - 160)
        let height = (width * 9 / 16).rounded()
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }
}

/// the league client's main window, by owner pid (league client and its ux helpers), in appkit coordinates.
@MainActor
enum ClientWindow {
    static func frame() -> CGRect? {
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            LeagueProcessWatcher.kind(bundleID: app.bundleIdentifier,
                                      executable: app.executableURL?.lastPathComponent) == .client ? app.processIdentifier : nil
        })
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: CGRect?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width >= 800, rect.height >= 450 else { continue }
            if best.map({ rect.width * rect.height > $0.width * $0.height }) ?? true { best = rect }
        }
        guard let best else { return nil }
        // core graphics: top-left origin on the primary display; appkit: bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: best.minX, y: primaryHeight - best.maxY, width: best.width, height: best.height)
    }
}

/// floats above the client, takes clicks, never takes keyboard focus (champ select chat keeps typing).
private final class BannerPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: BannerPlacement.fallbackWidth, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// the first click on apply or close acts right away, even though the panel never becomes key.
private final class BannerHostingView: NSHostingView<ChampSelectBanner> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
