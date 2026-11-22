import AppKit
import SwiftUI
import Observation
import CompanionCore

///
/// replaces swift ui's menu bar extra, whose status button reacts to the left mouse button only. here the button
/// sends its action on left *and* right mouse up, and both toggle the same popover (there is no context menu).
///
/// the popover is a borderless panel with an nsglass effect view (the same glass the menu bar extra window and
/// --popover-preview use) hosting popover view. it sits under the icon, follows the content height, and closes
/// on escape, on a click outside it, or on a second click on the icon.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: PopoverPanel?
    private var host: NSHostingController<PopoverView>?
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// when the panel last closed because focus left it. a click on the icon closes it that way first (on mouse
    /// down), so the toggle on mouse up must not reopen it straight away.
    private var lastAutoClose: ContinuousClock.Instant?

    private static let width: CGFloat = 300
    private static let gap: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    private static let autoCloseDebounce: Duration = .milliseconds(300)
    private static let minPanelHeight: CGFloat = 80
    private static let maxPanelHeight: CGFloat = 2000

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        trackIcon()
        observePulseConditions()
        playLaunchAnimation()
    }

    private static let launchHold: TimeInterval = 0.35
    private static let tickInterval: TimeInterval = 1.0 / 50
    private static let dotFade: CFTimeInterval = 0.2
    private static let fadeKey = "fade"

    private struct Transition {
        let from: CGFloat, to: CGFloat, duration: TimeInterval, start: CFTimeInterval
        let completion: () -> Void
    }

    private var currentState: MenuBarIcon.State = .asleep
    /// the eye as drawn: 0 shut (asleep image), 1 open (client or in game image).
    private var openness: CGFloat = 0
    /// which open eye image to show at openness 1: the in game one carries the ring cut out around the dot.
    private var openState: MenuBarIcon.State = .client
    private var transition: Transition?
    private var transitionTimer: Timer?
    private var launching = true
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func playLaunchAnimation() {
        guard !reduceMotion, statusItem.button != nil else {
            launching = false
            applyIcon(currentState)
            return
        }
        openness = 0
        show(0)
        setDot(visible: false, animated: false)
        run(to: 1, duration: MenuBarIcon.transitionDuration) { [weak self] in
            self?.run(to: 1, duration: Self.launchHold) {
                self?.launching = false
                self?.settle()
            }
        }
    }

    /// moves the shown state to the current one: eye open or shut with eased frames, dot faded in or out.
    private func settle() {
        guard let button = statusItem.button else { return }
        let state = currentState
        button.setAccessibilityLabel(state.accessibilityLabel)
        let target: CGFloat = state == .asleep ? 0 : 1
        if state == .inGame {
            openState = .inGame
        } else {
            setDot(visible: false, animated: true)
            if state == .asleep { openState = .client }
        }
        if transition != nil || abs(openness - target) > 0.001 {
            let distance = abs(target - openness)
            run(to: target, duration: max(MenuBarIcon.transitionDuration * distance, 0.15)) { [weak self] in
                guard let self else { return }
                self.show(self.openness)
                self.setDot(visible: self.currentState == .inGame, animated: true)
            }
        } else {
            show(openness)
            setDot(visible: state == .inGame, animated: true)
        }
    }

    private func run(to target: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        transitionTimer?.invalidate()
        transition = Transition(from: openness, to: target, duration: duration, start: CACurrentMediaTime(),
                                completion: completion)
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        transitionTimer = timer
    }

    private func tick() {
        guard let t = transition else { return }
        let progress = min(1, (CACurrentMediaTime() - t.start) / t.duration)
        let eased = 0.5 - 0.5 * cos(Double.pi * progress)
        openness = progress >= 1 ? t.to : t.from + (t.to - t.from) * CGFloat(eased)
        show(openness)
        guard progress >= 1 else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        transition = nil
        t.completion()
    }

    private func show(_ openness: CGFloat) {
        let image: NSImage
        if openness >= 1 {
            image = MenuBarIcon.image(for: openState)
        } else {
            let frames = MenuBarIcon.transitionFrames()
            image = frames[Int((openness * CGFloat(frames.count - 1)).rounded())]
        }
        if statusItem.button?.image !== image { statusItem.button?.image = image }
    }

    /// the static path: no animation, used under reduce motion.
    private func applyIcon(_ state: MenuBarIcon.State) {
        guard let button = statusItem.button else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        transition = nil
        openness = state == .asleep ? 0 : 1
        openState = state == .inGame ? .inGame : .client
        let image = MenuBarIcon.image(for: state)
        if button.image !== image {
            button.image = image
            button.setAccessibilityLabel(state.accessibilityLabel)
        }
        setDot(visible: state == .inGame, animated: false)
    }

    var isShown: Bool { panel?.isVisible == true }

    private func trackIcon() {
        let state = withObservationTracking {
            MenuBarIcon.State(model.coordinator.phase)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
        currentState = state
        guard !launching else { return }
        if reduceMotion { applyIcon(state) } else { settle() }
    }

    /// the teal badge, its own view over the eye so core animation can breathe it (opacity 1 to 0.55, scale 1 to
    /// 0.92, 2.4 s ease-in-out cycle) in the render server: no timers, no image redraws. added on entering the game,
    /// removed once faded out on leaving it; static under reduce motion, paused while the menu bar is hidden or the
    /// screens sleep. the fade runs on the view's layer, the pulse on the dot sublayer, so they do not fight.
    private var dotView: NSView?
    private var dotWanted = false
    private var screensAsleep = false
    private var occlusionObserver: NSObjectProtocol?
    private var pulseObservers: [NSObjectProtocol] = []
    private static let pulseKey = "pulse"

    private func setDot(visible: Bool, animated: Bool) {
        guard let button = statusItem.button else { return }
        dotWanted = visible
        let animated = animated && !reduceMotion
        if !visible {
            let finish = { [weak self] in
                guard let self, !self.dotWanted else { return }
                self.openState = .client
                self.dotLayer?.removeAllAnimations()
                self.dotView?.removeFromSuperview()
                self.dotView = nil
                if self.transition == nil { self.show(self.openness) }
            }
            if animated, let layer = dotView?.layer, layer.opacity != 0 {
                fade(layer, to: 0, completion: finish)
            } else {
                dotView?.layer?.removeAnimation(forKey: Self.fadeKey)
                finish()
            }
            return
        }
        let isNew = dotView == nil
        let view = dotView ?? {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.opacity = animated ? 0 : 1
            // the dot is a sublayer: app kit owns the view's own layer geometry, which would undo a centred anchor.
            let dot = CALayer()
            dot.backgroundColor = MenuBarIcon.accent.cgColor
            v.layer?.addSublayer(dot)
            v.setAccessibilityElement(false)
            button.addSubview(v)
            dotView = v
            return v
        }()
        positionDot(view, in: button)
        updatePulse()
        guard let layer = view.layer else { return }
        if animated {
            if layer.opacity != 1 || isNew { fade(layer, to: 1, completion: nil) }
        } else {
            layer.removeAnimation(forKey: Self.fadeKey)
            layer.opacity = 1
        }
    }

    private func fade(_ layer: CALayer, to value: Float, completion: (() -> Void)?) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: Self.fadeKey)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        layer.opacity = value
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = Self.dotFade
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    private func positionDot(_ view: NSView, in button: NSStatusBarButton) {
        let icon = MenuBarIcon.size(for: .inGame)
        let r = MenuBarIcon.dotRect
        let originX = button.bounds.midX - icon.width / 2
        let y = button.isFlipped
            ? button.bounds.midY + icon.height / 2 - r.maxY
            : button.bounds.midY - icon.height / 2 + r.minY
        view.frame = NSRect(x: originX + r.minX, y: y, width: r.width, height: r.height)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        if let dot = dotLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.bounds = CGRect(origin: .zero, size: r.size)
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.position = CGPoint(x: r.width / 2, y: r.height / 2)
            dot.cornerRadius = r.width / 2
            dot.contentsScale = button.window?.backingScaleFactor ?? 2
            CATransaction.commit()
        }
    }

    private var dotLayer: CALayer? { dotView?.layer?.sublayers?.first }

    private func updatePulse() {
        guard let layer = dotLayer else { return }
        let visible = statusItem.button?.window?.occlusionState.contains(.visible) ?? true
        let shouldPulse = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && visible && !screensAsleep
        let running = layer.animation(forKey: Self.pulseKey) != nil
        if shouldPulse, !running {
            layer.add(Self.makePulseAnimation(), forKey: Self.pulseKey)
        } else if !shouldPulse, running {
            layer.removeAnimation(forKey: Self.pulseKey)
        }
    }

    private static func makePulseAnimation() -> CAAnimationGroup {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = 0.55
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 0.92
        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = 1.2
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        return group
    }

    private func observePulseConditions() {
        let workspace = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            let name = note.name
            MainActor.assumeIsolated {
                guard let self else { return }
                switch name {
                case NSWorkspace.screensDidSleepNotification: self.screensAsleep = true
                case NSWorkspace.screensDidWakeNotification: self.screensAsleep = false
                default: break
                }
                self.updatePulse()
            }
        }
        pulseObservers = [
            workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                  queue: .main, using: handler),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main,
                                  using: handler),
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main,
                                  using: handler),
        ]
        if let window = statusItem.button?.window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: handler)
        }
    }

    @objc private func buttonClicked(_ sender: Any?) {
        toggle()
    }

    func toggle() {
        if isShown {
            close()
        } else if let last = lastAutoClose, ContinuousClock.now - last < Self.autoCloseDebounce {
            lastAutoClose = nil
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        position(panel)
        // a non-activating panel becomes key without activating the app (no focus steal from the game or client,
        // and no dependence on the system granting activation), so escape and the shortcuts work straight away.
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        installOutsideClickMonitor()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func makePanel() -> PopoverPanel {
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = host.view

        let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = glass
        panel.onCancel = { [weak self] in self?.close() }

        // the content height changes with the phase (asleep / client / in game): keep the top edge under the icon.
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                self.position(panel)
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeFromFocusLoss() }
        }
        self.host = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let host else { return }
        let fit = host.sizeThatFits(in: NSSize(width: Self.width, height: Self.maxPanelHeight))
        let size = NSSize(width: Self.width, height: max(ceil(fit.height), Self.minPanelHeight))

        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - size.width)
        let top = min(anchor.minY, visible.maxY) - Self.gap
        panel.setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width,
                              height: size.height), display: true)
    }

    private func closeFromFocusLoss() {
        guard isShown else { return }
        lastAutoClose = .now
        close()
    }

    /// clicks in other apps never reach this process's windows, so did resign key may not fire for them when the
    /// panel stayed key; a global monitor catches those.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeFromFocusLoss() }
        }
    }
}

final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
