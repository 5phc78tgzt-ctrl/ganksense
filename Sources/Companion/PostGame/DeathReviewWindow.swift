import AppKit
import SwiftUI
import Observation
import CompanionCore

/// borderless, always-dark league-style window for the post-game death review.
///
/// three ways in:
/// - live: `coordinator.pendingreview` appears (end-of-game flow, game process gone, at least one death) and the
///   window closes when it clears (lobby, champ select, queue, league exits);
/// - manual: `reopenlatest()` from the popover's "review last game" row, which stays until closed or the next
///   game starts;
/// - preview: `--review-preview`, which stays until quit.
///
/// it floats in the upper third of the screen and never activates the app, so it can't steal focus from the
/// client. closing it never touches the stored record.
@MainActor
final class DeathReviewWindow: NSObject, NSWindowDelegate {
    private enum Mode { case live, manual, preview }

    private let coordinator: Coordinator
    private var panel: ReviewPanel?
    private var mode = Mode.live
    private var shownID: String?
    private var closing = false

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func start() {
        observe()
    }

    /// sample record (`--review-preview`).
    func showPreview(_ record: GameRecord) {
        mode = .preview
        present(record, animated: false)
    }

    /// popover row: the most recent game with deaths, whatever the phase (except in a game).
    func reopenLatest() {
        guard coordinator.phase != .inGame, let record = coordinator.latestReviewableRecord else { return }
        if mode == .live, panel != nil, shownID == record.id { return }
        mode = .manual
        present(record, animated: true)
    }

    /// delete-all-data and similar: close whatever is showing without dismissing a record.
    func closeNow() {
        close(animated: false)
    }


    private func observe() {
        let (pending, phase) = withObservationTracking { (coordinator.pendingReview, coordinator.phase) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        switch mode {
        case .preview:
            return
        case .manual:
            if ReviewLifecycle.shouldCloseManual(phase: phase) { close(animated: true) }
        case .live:
            if let pending {
                guard pending.id != shownID else { return }
                present(pending, animated: true)
            } else if panel != nil {
                close(animated: true)
            }
        }
    }


    private func present(_ record: GameRecord, animated: Bool) {
        shownID = record.id
        let rows = DeathReviewView.rows(fitting: (targetScreen?.visibleFrame.height ?? 900) * 0.88)
        let host = NSHostingController(rootView: DeathReviewView(record: record, maxRows: rows) { [weak self] in self?.userClosed() })
        // sized once from the content; letting the hosting view drive the size can loop layout.
        host.sizingOptions = []
        let fit = host.sizeThatFits(in: NSSize(width: DeathReviewView.width, height: 4000))
        let size = NSSize(width: DeathReviewView.width, height: max(fit.height, 160))

        let isNew = panel == nil
        let w = panel ?? makePanel()
        panel = w
        w.contentViewController = nil
        w.contentView = host.view
        host.view.frame = NSRect(origin: .zero, size: size)
        retained = host
        w.setContentSize(size)
        if isNew { position(w) }

        if isNew {
            w.alphaValue = animated ? 0 : 1
            w.orderFrontRegardless()
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = fadeDuration
                    w.animator().alphaValue = 1
                }
            }
        } else {
            w.alphaValue = 1
            w.orderFrontRegardless()
        }
        AppLog.app.notice("Death review shown (\(String(describing: self.mode), privacy: .public))")
    }

    private var retained: NSViewController?

    private var targetScreen: NSScreen? {
        mode == .preview ? NSScreen.screens.first : (NSScreen.main ?? NSScreen.screens.first)
    }

    /// fade length for opening and closing.
    private var fadeDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.2
    }

    /// upper third of the screen; the preview always uses the primary screen.
    private func position(_ w: NSWindow) {
        guard let vf = targetScreen?.visibleFrame else { w.center(); return }
        w.setFrameTopLeftPoint(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.maxY - vf.height * 0.12))
    }

    private func makePanel() -> ReviewPanel {
        let w = ReviewPanel(contentRect: NSRect(x: 0, y: 0, width: DeathReviewView.width, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        return w
    }

    /// done / x / escape: closes, and ends the live review so it doesn't come straight back.
    private func userClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.mode == .live { self.coordinator.dismissReview() }
            self.close(animated: true)
        }
    }

    private func close(animated: Bool) {
        guard let w = panel, !closing else { return }
        closing = true
        let finish: @MainActor () -> Void = { [weak self] in
            w.orderOut(nil)
            self?.panel = nil
            self?.retained = nil
            self?.shownID = nil
            self?.mode = .live
            self?.closing = false
            AppLog.app.notice("Death review closed")
            self?.observe()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ [fadeDuration] ctx in
                ctx.duration = fadeDuration
                w.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in finish() } })
        } else {
            finish()
        }
    }
}

/// borderless panel that can still take key (for return / escape) without activating the app.
private final class ReviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
