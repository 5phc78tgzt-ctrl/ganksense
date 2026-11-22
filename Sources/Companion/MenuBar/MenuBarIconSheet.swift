import AppKit

/// --render-menu-icons <dir>: writes every menu bar icon state to png contact sheets (light and dark menu bar,
/// at 1x, 2x and 8x) for checking alignment, then quits.
@MainActor
enum MenuBarIconSheet {
    static func renderIfRequested(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--render-menu-icons"), args.indices.contains(i + 1) else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearance, background) in [("light", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
                                                ("dark", NSAppearance.Name.darkAqua, NSColor(white: 0.16, alpha: 1))] {
            for scale in [1, 2, 8] as [CGFloat] {
                let url = dir.appendingPathComponent("menu-icons-\(name)-\(Int(scale))x.png")
                write(sheet(appearance: NSAppearance(named: appearance)!, background: background, scale: scale), to: url)
            }
        }
        AppLog.app.notice("Menu bar icons rendered to \(dir.path, privacy: .public)")
        return true
    }

    private static func sheet(appearance: NSAppearance, background: NSColor, scale: CGFloat) -> NSBitmapImageRep {
        let states: [MenuBarIcon.State] = [.asleep, .client, .inGame]
        let pad: CGFloat = 6
        let statesWidth = states.reduce(pad) { $0 + MenuBarIcon.size(for: $1).width + pad }
        let frames = MenuBarIcon.transitionFrames()
        let frameWidth = frames.reduce(pad) { $0 + $1.size.width + pad }
        let width = max(statesWidth, frameWidth)
        let height: CGFloat = 2 * 18 + 3 * pad
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let rows: [(y: CGFloat, items: [(state: MenuBarIcon.State?, image: NSImage)])] = [
                (pad, states.map { ($0, MenuBarIcon.image(for: $0)) }),
                (2 * pad + 18, frames.map { (nil, $0) }),
            ]
            for row in rows {
            var x = pad
            for (state, image) in row.items {
                let rect = NSRect(origin: NSPoint(x: x, y: row.y), size: image.size)
                if scale >= 8 {
                    NSColor.systemRed.withAlphaComponent(0.5).setStroke()
                    let outline = NSBezierPath(rect: rect.insetBy(dx: -0.05, dy: -0.05))
                    outline.lineWidth = 0.1
                    outline.stroke()
                    NSColor.systemBlue.withAlphaComponent(0.35).setStroke()
                    let mid = NSBezierPath()
                    mid.move(to: NSPoint(x: rect.minX, y: rect.midY)); mid.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                    mid.lineWidth = 0.1
                    mid.stroke()
                }
                if image.isTemplate {
                    let tinted = NSImage(size: image.size, flipped: false) { r in
                        image.draw(in: r)
                        NSColor.labelColor.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)
                } else {
                    image.draw(in: rect)
                }
                if state == .inGame {
                    MenuBarIcon.accent.setFill()
                    NSBezierPath(ovalIn: MenuBarIcon.dotRect.offsetBy(dx: rect.minX, dy: rect.minY)).fill()
                }
                x += image.size.width + pad
            }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
