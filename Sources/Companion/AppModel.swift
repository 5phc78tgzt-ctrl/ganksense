import AppKit
import Observation
import CompanionCore

@MainActor @Observable
final class AppModel {
    let coordinator: Coordinator
    let isDemo: Bool

    enum LaunchState: Equatable { case idle, starting, notInstalled, failed }
    private(set) var launchState: LaunchState = .idle

    /// shows the overlay with demo data for a few seconds (settings › overlay). set by the overlay controller;
    /// nil until one exists, which disables the button.
    var showOverlayPreview: (() -> Void)?
    /// the settings overlay preview closes at this time (nil: not running).
    var overlayPreviewEndsAt: Date?

    /// opens the settings window (set by app delegate). the popover is hosted by appkit, outside any swiftui
    /// scene, so the open settings environment action is only the fallback (the popover preview).
    @ObservationIgnored var openSettings: (() -> Void)?

    @ObservationIgnored var reopenReview: (() -> Void)?
    @ObservationIgnored var closeReview: (() -> Void)?

    /// result of the last Apply click, tied to the page it wrote (a new champion's page shows no stale result).
    struct RuneApplyStatus: Equatable {
        enum State: Equatable { case applying, applied, noFreeSlot, failed }
        var page: RunePage
        var state: State
    }
    private(set) var runeApply: RuneApplyStatus?

    /// a newer version listed on ganksense.app; nil when up to date, unchecked or switched off.
    private(set) var availableUpdate: String?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    private static let notifiedUpdateKey = "notifiedUpdateVersion"

    /// nil outside an app bundle, where there is nothing to compare against.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// debug (--update-preview): shows the update notice without asking the site.
    private static func previewUpdate(_ arguments: [String]) -> String? {
        arguments.contains("--update-preview") ? "9.9.9" : nil
    }

    func copyUpdateCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.command, forType: .string)
    }

    /// runs the daily check while the setting is on; called again whenever settings change.
    private func followUpdateSetting(current: String) {
        let enabled = withObservationTracking { coordinator.settings.checkForUpdates } onChange: { [weak self] in
            Task { @MainActor in self?.followUpdateSetting(current: current) }
        }
        guard enabled != (updateTask != nil) else { return }
        guard enabled else {
            updateTask?.cancel()
            updateTask = nil
            availableUpdate = nil
            return
        }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.checkForUpdate(current: current) else { return }
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// returns how long to wait before the next check: a day, or an hour after a failure or a postponed notice.
    private func checkForUpdate(current: String) async -> Duration {
        let soon = Duration.seconds(60 * 60), tomorrow = Duration.seconds(24 * 60 * 60)
        guard let latest = await UpdateCheck.latestVersion(), !Task.isCancelled else { return soon }
        availableUpdate = UpdateCheck.isNewer(latest, than: current) ? latest : nil
        guard let version = availableUpdate,
              UserDefaults.standard.string(forKey: Self.notifiedUpdateKey) != version
        else { return tomorrow }
        // never a banner over a game or champ select.
        guard coordinator.phase != .inGame, !inChampSelect else { return soon }
        notifier.notifyUpdate(version: version)
        UserDefaults.standard.set(version, forKey: Self.notifiedUpdateKey)
        return tomorrow
    }

    /// the champ select banner with sample data (settings demo, or --popover-preview champselect).
    var champSelectPreview = false

    /// settings: shows the banner with sample data until it's closed or a real champ select starts.
    func startBannerDemo() {
        guard !champSelectPreview, coordinator.phase != .client(.champSelect) else { return }
        runeApply = nil
        bannerDismissed = false
        bannerExpanded = false
        preferMatchupRunes = true
        personalRecordPreview = PopoverPreview.sampleRecord
        coordinator.advisor.showPreview(advice: PopoverPreview.sampleAdvice, champion: "Ahri", role: .mid,
                                        matchup: PopoverPreview.sampleMatchup, championID: "Ahri",
                                        warnings: ["No frontline"])
        champSelectPreview = true
    }

    func endBannerDemo() {
        guard champSelectPreview else { return }
        champSelectPreview = false
        personalRecordPreview = nil
        runeApply = nil
        bannerDismissed = false
        bannerExpanded = false
        coordinator.advisor.endPreview()
    }

    var inChampSelect: Bool { champSelectPreview || coordinator.phase == .client(.champSelect) }

    /// the page matched to my lane opponent, when op.gg has enough games on it and it differs from the standard one.
    var matchupRunes: RunePage? {
        let advisor = coordinator.advisor
        guard let page = advisor.matchup?.runes, page.perkIDs != advisor.advice?.runes?.perkIDs else { return nil }
        return page
    }

    /// false: the standard page even when a matchup page exists. back to the matchup page each champ select.
    var preferMatchupRunes = true

    /// the page the banner shows and Apply writes.
    var shownRunes: RunePage? {
        if preferMatchupRunes, let page = matchupRunes { return page }
        return coordinator.advisor.advice?.runes
    }

    /// debug preview: fixed record instead of the stored games.
    var personalRecordPreview: PersonalRecord?

    /// my games on the champion I hold, and into the lane opponent.
    var personalRecord: PersonalRecord? {
        if let personalRecordPreview { return personalRecordPreview }
        guard let id = coordinator.advisor.myChampionID else { return nil }
        let record = PersonalRecord.compute(records: coordinator.records, championID: id,
                                            opponent: coordinator.advisor.enemyName)
        return record.champion.games > 0 ? record : nil
    }

    /// writes the shown rune page into our own "ganksense" page. only ever from the Apply button.
    func applyRunes() {
        if champSelectPreview, let page = shownRunes {
            // demo: nothing is written to the client.
            runeApply = RuneApplyStatus(page: page, state: .applied)
            return
        }
        guard let page = shownRunes, let lcu, runeApply?.state != .applying else { return }
        runeApply = RuneApplyStatus(page: page, state: .applying)
        Task {
            let outcome = await lcu.applyRunePage(page)
            let state: RuneApplyStatus.State = switch outcome {
            case .applied: .applied
            case .noFreeSlot: .noFreeSlot
            case .invalidPage, .failed: .failed
            }
            runeApply = RuneApplyStatus(page: page, state: state)
        }
    }

    var reviewHint: String? {
        coordinator.latestReviewableRecord.map(ReviewLifecycle.hint(for:))
    }

    /// only for icon urls (item icon url is nonisolated and does no i/o).
    @ObservationIgnored let dataDragon: DataDragon
    @ObservationIgnored private let watcher: LeagueProcessWatching
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let lcu: LCUConnection?
    @ObservationIgnored private let demoDirectory: URL?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var launchResetTask: Task<Void, Never>?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent(AppInfo.name, isDirectory: true)
        dataDragon = DataDragon(cacheDir: caches.appendingPathComponent("ddragon", isDirectory: true))
        isDemo = arguments.contains("--demo")
        availableUpdate = Self.previewUpdate(arguments)
        notifier = Notifier(enabled: !isDemo)

        if isDemo {
            // throwaway store: the demo game is recorded like a real one. stores left by killed demo runs go too.
            let tmp = FileManager.default.temporaryDirectory
            let prefix = "\(AppInfo.name)-demo-"
            for old in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where old.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(old))
            }
            let dir = tmp.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
            demoDirectory = dir
            coordinator = Coordinator.demo(store: Store(directory: dir))
            watcher = DemoProcessWatcher()
            lcu = nil
        } else {
            demoDirectory = nil
            let lcu = LCUConnection()
            let patchRef = PatchRef()
            let watcher = LeagueProcessWatcher()
            self.lcu = lcu
            self.watcher = watcher
            coordinator = Coordinator(
                store: Store(directory: Store.defaultDirectory),
                dataDragon: dataDragon,
                makeClient: { lcu },
                live: LiveClient(),
                buildSource: CurrentPatchOPGG(cacheDir: caches.appendingPathComponent("opgg", isDirectory: true),
                                              patch: { await patchRef.version() })
            )
            patchRef.coordinator = coordinator
        }
    }

    /// debug (--popover-preview): wraps an already-driven demo coordinator for a stand-alone popover view.
    /// no watcher, no notifications; stop() removes directory (its throwaway store).
    init(previewCoordinator: Coordinator, directory: URL) {
        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent(AppInfo.name, isDirectory: true)
        dataDragon = DataDragon(cacheDir: caches.appendingPathComponent("ddragon", isDirectory: true))
        isDemo = false
        availableUpdate = Self.previewUpdate(ProcessInfo.processInfo.arguments)
        notifier = Notifier(enabled: false)
        coordinator = previewCoordinator
        watcher = DemoProcessWatcher()
        lcu = nil
        demoDirectory = directory
    }

    func start() {
        guard !started else { return }
        started = true
        let notifier = self.notifier
        coordinator.onTiltNudge = { message in notifier.notifyTilt(message) }
        coordinator.onMatchFound = { [weak self] accepted in
            guard let self, self.coordinator.settings.notifyMatchFound else { return }
            AppLog.app.notice("Match found, \(accepted ? "accepted" : "not accepted", privacy: .public)")
            // you're looking at the client already: it shows the check itself.
            if let front = NSWorkspace.shared.frontmostApplication,
               LeagueProcessWatcher.kind(bundleID: front.bundleIdentifier,
                                         executable: front.executableURL?.lastPathComponent) == .client { return }
            notifier.notifyMatchFound(accepted: accepted)
        }
        coordinator.onHowlingAbyssGame = { mode in
            AppLog.app.notice("Howling Abyss game detected, game mode \(mode, privacy: .public)")
        }
        coordinator.start()
        watcher.start { [weak self] client, game in
            guard let self else { return }
            if !client, let lcu = self.lcu { Task { await lcu.reset() } }
            self.coordinator.leagueProcessChanged(clientRunning: client, gameRunning: game)
            if client || game { self.clearLaunchState() }
        }
        logPhaseChanges()
        if !isDemo, availableUpdate == nil, let current = Self.appVersion {
            Task { [weak self] in
                await self?.coordinator.waitForSettings()
                self?.followUpdateSetting(current: current)
            }
        }
        if isDemo { demoExitWhenFinished() }
    }

    private func demoExitWhenFinished() {
        let phase = withObservationTracking { coordinator.phase } onChange: { [weak self] in
            Task { @MainActor in self?.demoExitWhenFinished() }
        }
        if phase == .postGame { (watcher as? DemoProcessWatcher)?.exitGame() }
    }


    var dataFolder: URL { isDemo ? (demoDirectory ?? Store.defaultDirectory) : Store.defaultDirectory }

    func deleteAllData() {
        closeReview?()
        coordinator.purgeHistory()
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppInfo.name, isDirectory: true) {
            try? fm.removeItem(at: caches)
        }
        AppLog.app.notice("Deleted game history and caches")
    }

    private func logPhaseChanges() {
        let phase = withObservationTracking { coordinator.phase } onChange: { [weak self] in
            Task { @MainActor in self?.logPhaseChanges() }
        }
        AppLog.app.notice("Phase: \(String(describing: phase), privacy: .public)")
    }

    func stop() {
        updateTask?.cancel()
        watcher.stop()
        coordinator.stop()
        if let demoDirectory { try? FileManager.default.removeItem(at: demoDirectory) }
    }


    func launchLeague() {
        guard launchState != .starting else { return }
        launchState = .starting
        Task {
            let outcome = await LeagueLauncher.launch()
            switch outcome {
            case .launched:
                // the watcher clears this once the client appears; give up quietly after a minute.
                launchResetTask?.cancel()
                launchResetTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, self?.launchState == .starting else { return }
                    self?.launchState = .idle
                }
            case .notInstalled: launchState = .notInstalled
            case .failed: launchState = .failed
            }
        }
    }

    private func clearLaunchState() {
        launchResetTask?.cancel(); launchResetTask = nil
        launchState = .idle
    }


    func itemIconURL(_ id: Int) -> URL? {
        guard let version = coordinator.itemCatalog?.version else { return nil }
        return dataDragon.itemIconURL(id: id, version: version)
    }

    func championIconURL(key: Int) -> URL? {
        guard let catalog = coordinator.championCatalog, let champ = catalog.champion(key: key) else { return nil }
        return dataDragon.championIconURL(id: champ.id, version: catalog.version)
    }

    /// rune and spell art for the banner, loaded once per patch when the first champ select needs it.
    private(set) var icons: IconCatalog?
    @ObservationIgnored private var iconsTask: Task<Void, Never>?

    func loadIcons() {
        guard iconsTask == nil, icons == nil else { return }
        let dragon = dataDragon
        let known = coordinator.championCatalog?.version
        iconsTask = Task {
            let version: String? = if let known { known } else { try? await dragon.latestVersion() }
            if let version { icons = try? await dragon.icons(version: version) }
            iconsTask = nil
        }
    }

    func championIconURL(id: String?) -> URL? {
        guard let id, let version = coordinator.championCatalog?.version else { return nil }
        return dataDragon.championIconURL(id: id, version: version)
    }

    /// the champ select banner was closed with its x; reset when the next champ select starts.
    var bannerDismissed = false
    /// the slim bar was opened into the full banner (reset each champ select).
    var bannerExpanded = false
}

/// companion core.settings (swiftui also has a settings scene).
typealias AppSettings = CompanionCore.Settings

/// breaks the init cycle between the op.gg source and the coordinator whose catalog it reads.
@MainActor
private final class PatchRef {
    weak var coordinator: Coordinator?
    func version() -> String? { coordinator?.itemCatalog?.version }
}
