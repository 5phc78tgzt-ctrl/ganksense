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

    /// opens the settings window (set by app delegate). the popover is hosted by appkit, outside any swiftui
    /// scene, so the open settings environment action is only the fallback (the popover preview).
    @ObservationIgnored var openSettings: (() -> Void)?

    @ObservationIgnored var reopenReview: (() -> Void)?
    @ObservationIgnored var closeReview: (() -> Void)?

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
        coordinator.start()
        watcher.start { [weak self] client, game in
            guard let self else { return }
            if !client, let lcu = self.lcu { Task { await lcu.reset() } }
            self.coordinator.leagueProcessChanged(clientRunning: client, gameRunning: game)
            if client || game { self.clearLaunchState() }
        }
        logPhaseChanges()
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
}

/// companion core.settings (swiftui also has a settings scene).
typealias AppSettings = CompanionCore.Settings

/// breaks the init cycle between the op.gg source and the coordinator whose catalog it reads.
@MainActor
private final class PatchRef {
    weak var coordinator: Coordinator?
    func version() -> String? { coordinator?.itemCatalog?.version }
}
