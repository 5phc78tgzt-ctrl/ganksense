import SwiftUI
import AppKit
import CompanionCore

/// data dragon item pngs: on-disk cache under `caches/<app>/icons/<version>/<id>.png`, one download per icon
/// (in-flight requests are shared). returns bytes; images are decoded on the main actor by `itemiconstore`.
actor ItemIconCache {
    static let shared = ItemIconCache()

    private let root: URL
    private let session: URLSession
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = caches.appendingPathComponent(AppInfo.name, isDirectory: true).appendingPathComponent("icons", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        let root = self.root
        Task.detached(priority: .background) { Self.prune(root, keep: 2) }
    }

    /// every patch gets its own folder; keep the newest `keep` patch folders and drop the rest so the cache stops
    /// growing by a patch's worth of icons every two weeks. folders not named like a patch are left alone.
    nonisolated static func prune(_ root: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        func parts(_ name: String) -> [Int]? {
            let comps = name.split(separator: ".", omittingEmptySubsequences: false)
            let nums = comps.compactMap { Int($0) }
            return comps.count >= 2 && nums.count == comps.count ? nums : nil
        }
        let versions = names.compactMap { n in parts(n).map { (n, $0) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
        for (name, _) in versions.dropLast(keep) {
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    func data(for url: URL) async -> Data? {
        let file = diskURL(for: url)
        if let data = try? Data(contentsOf: file) { return data }
        if let task = inFlight[url] { return await task.value }
        let session = self.session
        let task = Task<Data?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        return data
    }

    /// `…/cdn/<version>/img/item/<id>.png` → `icons/<version>/<id>.png`.
    private func diskURL(for url: URL) -> URL {
        let parts = url.pathComponents
        let version = parts.count >= 4 ? parts[parts.count - 4] : "unknown"
        return root.appendingPathComponent(version, isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }
}

/// decoded icons kept in memory for the life of the process (a game uses a few dozen).
@MainActor
enum ItemIconStore {
    private static var images: [URL: NSImage] = [:]

    static func cached(_ url: URL) -> NSImage? { images[url] }

    static func load(_ url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        guard let data = await ItemIconCache.shared.data(for: url), let image = NSImage(data: data) else { return nil }
        images[url] = image
        return image
    }
}

/// square item icon in a gold league frame; a dark gold-framed placeholder while loading or offline.
struct ItemIcon: View {
    let url: URL?
    var size: CGFloat = 36
    var frameColor: Color = LeagueTheme.gold

    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .circular)
        ZStack {
            shape.fill(LinearGradient(colors: [LeagueTheme.navy, LeagueTheme.navyDeep], startPoint: .top, endPoint: .bottom))
            if let image = url.flatMap(ItemIconStore.cached) ?? image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .strokeBorder(LeagueTheme.bronze.opacity(0.6), lineWidth: 1)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.inset(by: 1).strokeBorder(.black.opacity(0.6), lineWidth: 1))
        .overlay(shape.strokeBorder(frameColor, lineWidth: 1))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ItemIconStore.cached(url) { image = hit; return }
            image = nil
            let loaded = await ItemIconStore.load(url)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
