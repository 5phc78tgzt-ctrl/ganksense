import SwiftUI
import AppKit
import CompanionCore

///
/// hidden debug flags (for screenshots): --scout-preview shows the loading screen scout card with sample players until quit;
/// --overlay-preview [aram] shows the overlay with static demo data (aram: howling abyss look) until quit;
/// --review-preview [victory|defeat|none] shows the death review for a sample demo game with that result (default
/// victory);
/// --settings-preview <general|overlay|goals|tilt> shows the settings view in a plain window on that tab;
/// --render-menu-icons <dir> writes the menu bar icons to png sheets and quits;
/// --popover-preview <asleep|client|ingame|champselect|patterns|scout> shows the menu bar popover in a floating window
/// (champselect also shows the champ select banner above a stand-in 1280x720 client; --banner-client <width> sets it). all stay
/// until quit, at fixed positions on the primary screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var overlay: OverlayController?
    private var banner: ChampSelectBannerController?
    private var scoutCard: ScoutCardController?
    private var deathReview: DeathReviewWindow?
    private var popoverPreview: PopoverPreview?
    private var settingsPreviewWindow: NSWindow?
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MenuBarIconSheet.renderIfRequested(ProcessInfo.processInfo.arguments) { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.openSettings = { [weak self] in self?.showSettings() }

        let overlay = OverlayController(model: model)
        overlay.start()
        self.overlay = overlay
        let scoutCard = ScoutCardController(model: model)
        scoutCard.start()
        self.scoutCard = scoutCard
        if PopoverPreview.mode(from: ProcessInfo.processInfo.arguments) == nil {
            let banner = ChampSelectBannerController(model: model)
            banner.start()
            self.banner = banner
            if ProcessInfo.processInfo.arguments.contains("--banner-demo") { model.startBannerDemo() }
        }
        let deathReview = DeathReviewWindow(coordinator: model.coordinator)
        deathReview.start()
        self.deathReview = deathReview
        model.reopenReview = { [weak self] in
            self?.statusItem?.close()
            self?.deathReview?.reopenLatest()
        }
        model.closeReview = { [weak deathReview] in deathReview?.closeNow() }

        let args = ProcessInfo.processInfo.arguments
        if args.contains("--overlay-preview") { overlay.showPreview(persistent: true) }
        if args.contains("--scout-preview") { scoutCard.showPreview(PopoverPreview.sampleScout) }
        if args.contains("--review-preview") {
            Task {
                let variant = args.firstIndex(of: "--review-preview").flatMap { i in args.indices.contains(i + 1) ? args[i + 1] : nil }
                let win: Bool? = switch variant {
                case "defeat": false
                case "remake", "none": nil
                default: true
                }
                if let record = await PreviewData.reviewRecord(win: win) { deathReview.showPreview(record, patternLine: "Last 10 games: most common likely cause was jungler gank (41% of deaths)") }
            }
        }
        if args.contains("--settings-preview") {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.setFrameTopLeftPoint(NSPoint(x: 120, y: (NSScreen.main?.frame.height ?? 900) - 60))
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            settingsPreviewWindow = window
        }
        if let mode = PopoverPreview.mode(from: args) {
            let preview = PopoverPreview()
            popoverPreview = preview
            Task { await preview.show(mode) }
        }
    }

    func showSettings() {
        statusItem?.close()
        let window = settingsWindow ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            return w
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        popoverPreview?.stop()
    }
}

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // the menu bar icon and popover are appkit (the status item controller); an app needs a scene, and this one
        // also serves the standard settings command.
        SwiftUI.Settings {
            SettingsView(model: delegate.model)
        }
    }
}
