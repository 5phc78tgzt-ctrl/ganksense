import AppKit
import SwiftUI
import CompanionCore

/// menu bar glyphs: template images (black on clear) that the menu bar tints for light, dark and highlighted
/// states. the one accent, the azure in-game dot, is a separate layer on the status button (status item controller).
enum MenuBarIcon {
    enum State: Equatable {
        case asleep, client, queue, matchFound, inGame

        init(_ phase: AppPhase) {
            switch phase {
            case .asleep: self = .asleep
            case .client(.matchmaking): self = .queue
            case .client(.readyCheck): self = .matchFound
            case .client, .postGame: self = .client
            case .inGame: self = .inGame
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .asleep: "\(AppInfo.name), League closed"
            case .client: "\(AppInfo.name), League open"
            case .queue: "\(AppInfo.name), searching for a match"
            case .matchFound: "\(AppInfo.name), match found"
            case .inGame: "\(AppInfo.name), in game"
            }
        }
    }

    /// 18 pt tall like system items; the eye glyph is wider than tall, so every state gets the same 22 pt canvas
    /// and the status item keeps one width across phases.
    static func size(for state: State) -> NSSize {
        NSSize(width: 22, height: 18)
    }

    private static var eyeConfig: NSImage.SymbolConfiguration { .init(pointSize: 12, weight: .medium) }

    static let accent = NSColor(srgbRed: 0x3B / 255, green: 0x9E / 255, blue: 0xFF / 255, alpha: 1)

    @MainActor private static var cache: [State: NSImage] = [:]

    @MainActor
    static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = make(state)
        cache[state] = image
        return image
    }

    /// eye transition frames: frame 0 is exactly the shut eye (asleep icon), the last exactly the open eye (client icon),
    /// evenly spaced in openness. the animator maps eased time to a frame, so the easing lives in the timing.
    static let transitionFrameCount = 21
    static let transitionDuration: TimeInterval = 0.4

    @MainActor private static var frameCache: [NSImage] = []

    @MainActor
    static func transitionFrames() -> [NSImage] {
        if frameCache.isEmpty {
            let last = CGFloat(transitionFrameCount - 1)
            frameCache = (0..<transitionFrameCount).map { eyeFrame(openness: CGFloat($0) / last) }
        }
        return frameCache
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// the open eye's height grows from a thin slit around the box centre; the shut lid and lashes fade out over the
    /// first third of the opening while the eye fades in.
    @MainActor
    private static func eyeFrame(openness: CGFloat) -> NSImage {
        if openness <= 0 { return image(for: .asleep) }
        if openness >= 1 { return image(for: .client) }
        let shut = image(for: .asleep)
        let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(eyeConfig)
        let shutAlpha = 1 - smoothstep(openness / 0.35)
        let eyeAlpha = smoothstep(openness / 0.3)
        let image = NSImage(size: size(for: .client), flipped: false) { rect in
            shut.draw(in: rect, from: .zero, operation: .sourceOver, fraction: shutAlpha)
            if let symbol {
                let s = symbol.size
                let scaleY = 0.1 + 0.9 * openness
                let origin = NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2)
                let box = NSRect(origin: origin, size: s).integral
                let squashed = NSRect(x: box.minX, y: box.midY - box.height * scaleY / 2, width: box.width,
                                      height: box.height * scaleY)
                symbol.draw(in: squashed, from: .zero, operation: .sourceOver, fraction: eyeAlpha)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func make(_ state: State) -> NSImage {
        switch state {
        case .asleep: makeAsleep()
        case .queue: queueFrame(look: 0)
        case .matchFound: makeMatchFound()
        case .client, .inGame: makeEye(state)
        }
    }

    /// queue: a squinted eye hunting for something. `look` -1...1 slides the pupil across.
    static let queueCycle: TimeInterval = 2.6
    static let queueFrameCount = 26

    /// pupil position over one cycle: centre, left, hold, right, hold, back (eased moves between holds).
    static func queueLook(at phase: Double) -> CGFloat {
        let keys: [(Double, CGFloat)] = [(0, 0), (0.12, -1), (0.42, -1), (0.58, 1), (0.88, 1), (1, 0)]
        for i in 1..<keys.count where phase <= keys[i].0 {
            let (t0, v0) = keys[i - 1], (t1, v1) = keys[i]
            let f = CGFloat((phase - t0) / (t1 - t0))
            return v0 + (v1 - v0) * smoothstep(f)
        }
        return 0
    }

    @MainActor private static var queueCache: [NSImage] = []

    @MainActor
    static func queueFrames() -> [NSImage] {
        if queueCache.isEmpty {
            queueCache = (0..<queueFrameCount).map { queueFrame(look: queueLook(at: Double($0) / Double(queueFrameCount))) }
        }
        return queueCache
    }

    private static func queueFrame(look: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let left = NSPoint(x: 3.2, y: rect.midY), right = NSPoint(x: 18.1, y: rect.midY)
            let lift: CGFloat = 4.6
            let lid = NSBezierPath()
            lid.move(to: left)
            lid.curve(to: right, controlPoint1: NSPoint(x: left.x + 4.5, y: left.y + lift),
                      controlPoint2: NSPoint(x: right.x - 4.5, y: right.y + lift))
            lid.curve(to: left, controlPoint1: NSPoint(x: right.x - 4.5, y: right.y - lift),
                      controlPoint2: NSPoint(x: left.x + 4.5, y: left.y - lift))
            lid.lineWidth = 1.6
            lid.lineJoinStyle = .round
            lid.stroke()
            let r: CGFloat = 1.9
            NSBezierPath(ovalIn: NSRect(x: rect.midX + look * 3.4 - r, y: rect.midY - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = State.queue.accessibilityLabel
        return image
    }

    /// match found: the open eye, wide awake, with three alert rays above it.
    private static func makeMatchFound() -> NSImage {
        let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(eyeConfig)
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            if let symbol {
                let s = symbol.size
                symbol.draw(in: NSRect(origin: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2 - 1.5),
                                       size: s).integral)
            }
            NSColor.black.set()
            let rays = NSBezierPath()
            for (x, dx, h) in [(6.0, -1.6, 2.6), (11.0, 0.0, 3.4), (16.0, 1.6, 2.6)] as [(CGFloat, CGFloat, CGFloat)] {
                rays.move(to: NSPoint(x: x, y: 14.4))
                rays.line(to: NSPoint(x: x + dx, y: 14.4 + h))
            }
            rays.lineWidth = 1.5
            rays.lineCapStyle = .round
            rays.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = State.matchFound.accessibilityLabel
        return image
    }

    /// the in-game badge dot, in icon coordinates (origin bottom-left of the 22 x 18 box): on the eye's lower-right
    /// outline (the eye's right corner is at about x 19, y 9), fully inside the box. not part of the image: the
    /// status item draws it as its own layer so it can pulse (status item controller).
    static let dotRect = NSRect(x: 16.6, y: 1.4, width: 5, height: 5)
    static let dotRing: CGFloat = 1

    private static func makeEye(_ state: State) -> NSImage {
        let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(eyeConfig)
        let hasDot = state == .inGame

        let image = NSImage(size: size(for: state), flipped: false) { rect in
            if let symbol {
                let s = symbol.size
                let origin = NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2)
                symbol.draw(in: NSRect(origin: origin, size: s).integral)
            }
            if hasDot {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -dotRing, dy: -dotRing)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    private static func makeAsleep() -> NSImage {
        let canvas = size(for: .asleep)

        let image = NSImage(size: canvas, flipped: false) { _ in
            NSColor.black.set()
            // horizontally matches the visible outline of the open eye symbol as drawn in the 22 pt canvas: corners at x 2.4 and
            // 18.9, 1.6 pt stroke; then shifted so the shut eye sits centred in the box.
            let stroke: CGFloat = 1.6
            let left = NSPoint(x: 2.4 + stroke / 2, y: canvas.height / 2)
            let right = NSPoint(x: 18.9 - stroke / 2, y: canvas.height / 2)
            let width = right.x - left.x
            let sag: CGFloat = 4
            let c1 = NSPoint(x: left.x + width * 0.25, y: left.y - sag)
            let c2 = NSPoint(x: right.x - width * 0.25, y: right.y - sag)
            let lid = NSBezierPath()
            lid.move(to: left)
            lid.curve(to: right, controlPoint1: c1, controlPoint2: c2)
            lid.lineWidth = stroke
            lid.lineCapStyle = .round

            func point(_ t: CGFloat) -> NSPoint {
                let u = 1 - t
                return NSPoint(x: u * u * u * left.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * right.x,
                               y: u * u * u * left.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * right.y)
            }
            let lashes = NSBezierPath()
            for (t, dx) in [(0.24, -1.1), (0.5, 0.0), (0.76, 1.1)] as [(CGFloat, CGFloat)] {
                let p = point(t)
                lashes.move(to: NSPoint(x: p.x + dx * 0.2, y: p.y - 0.6))
                lashes.line(to: NSPoint(x: p.x + dx, y: p.y - 2.9))
            }
            lashes.lineWidth = 1.25
            lashes.lineCapStyle = .round

            let top = lid.bounds.maxY + stroke / 2
            let bottom = min(lid.bounds.minY - stroke / 2, lashes.bounds.minY - lashes.lineWidth / 2)
            let shift = AffineTransform(translationByX: 0, byY: canvas.height / 2 - (top + bottom) / 2)
            lid.transform(using: shift)
            lashes.transform(using: shift)
            lid.stroke()
            lashes.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = State.asleep.accessibilityLabel
        return image
    }
}
