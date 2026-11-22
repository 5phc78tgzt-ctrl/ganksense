// no testing import here: the command line tools lack the testing/foundation overlay, so no file may import both.
import Foundation
import Synchronization
@testable import CompanionCore

/// real clock running 1000x fast, so a 1 s poll takes 1 ms.
struct FastClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    private let base = ContinuousClock()
    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await base.sleep(for: base.now.duration(to: deadline) / 1000)
    }
}

/// replays a fixed script, then repeats `then` forever.
final class ScriptedLive: LiveGameSource, Sendable {
    enum Item: Sendable {
        case snap(LiveGameSnapshot)
        case notReady
        case notRunning
    }

    private let state: Mutex<(script: [Item], calls: Int)>
    private let then: Item

    init(_ script: [Item], then: Item = .notRunning) {
        state = Mutex((script, 0))
        self.then = then
    }

    var calls: Int { state.withLock { $0.calls } }

    func fetch() async throws -> LiveGameSnapshot {
        let item = state.withLock { s -> Item in
            defer { s.calls += 1 }
            return s.calls < s.script.count ? s.script[s.calls] : then
        }
        switch item {
        case .snap(let snapshot): return snapshot
        case .notReady: throw LiveClientError.notReady
        case .notRunning: throw LiveClientError.notRunning
        }
    }
}

/// answers whatever the test last set.
final class ControlledLive: LiveGameSource, Sendable {
    private let state = Mutex<(item: ScriptedLive.Item, calls: Int)>((.notRunning, 0))
    func set(_ item: ScriptedLive.Item) { state.withLock { $0.item = item } }
    var calls: Int { state.withLock { $0.calls } }
    func fetch() async throws -> LiveGameSnapshot {
        let item = state.withLock { s -> ScriptedLive.Item in s.calls += 1; return s.item }
        switch item {
        case .snap(let snapshot): return snapshot
        case .notReady: throw LiveClientError.notReady
        case .notRunning: throw LiveClientError.notRunning
        }
    }
}

final class FakeClient: ClientSource, Sendable {
    private let state = Mutex<(phase: GameflowPhase, calls: Int)>((.lobby, 0))
    func set(_ p: GameflowPhase) { state.withLock { $0.phase = p } }
    func phase() async throws -> GameflowPhase { state.withLock { s in s.calls += 1; return s.phase } }
    func champSelect() async throws -> ChampSelectInfo? { nil }
    func recentMatches(count: Int) async throws -> [MatchSummary] { [] }
}

func makeTempStore() -> Store {
    Store(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true))
}

func writeGarbage(_ store: Store, file: String) {
    try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try? Data("{not json".utf8).write(to: store.directory.appendingPathComponent(file))
}

func writeFile(_ store: Store, file: String, _ contents: String) {
    try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try? Data(contents.utf8).write(to: store.directory.appendingPathComponent(file))
}

func fileNames(_ store: Store) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
}

func decodeSettings(_ json: String) -> Settings? {
    try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

func sampleRecord(id: String = "1700000000-Jinx") -> GameRecord {
    GameRecord(id: id, date: Date(timeIntervalSince1970: 1_700_000_000.25), champion: "Jinx", role: .adc,
               win: false,
               goalResult: GoalProgress(goal: Goal(preset: .csAt10, target: 70), current: 72, state: .achieved,
                                        label: "72 / 70 CS", deadline: 600),
               deaths: [DeathEvent(id: 3, time: 410.5, killer: "Zed"),
                        DeathEvent(id: 7, time: 655, killer: "Draven", assisters: ["Soraka"])],
               durationSec: 1820, isVoid: false)
}

/// coordinator on the fast clock with bundled catalogs (no data dragon, no op.gg).
@MainActor
func makeCoordinator(live: LiveGameSource, client: FakeClient? = nil, store: Store = makeTempStore()) -> Coordinator {
    Coordinator(store: store, dataDragon: nil, makeClient: { client }, live: live, buildSource: nil,
                clock: FastClock())
}

/// midgame fixture moved to `time`, with a game end event appended when `ended`.
func midgame(time: Double, ended: Bool = false, result: String = "Win") throws -> LiveGameSnapshot {
    var s = try loadSnapshot("allgamedata_midgame")
    s.gameData?.gameTime = time
    if ended { s.events.append(GameEvent(id: 99, name: "GameEnd", time: time, result: result)) }
    return s
}

func jsonString(_ value: some Encodable) -> String {
    (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

func backupCount(_ store: Store) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
    return names.filter { $0.hasPrefix("records.corrupt-") }.count
}

/// records file holding `good` plus one corrupt record (a death time that is not a number).
func writeRecordsWithOneBad(_ store: Store, good: GameRecord) {
    let enc = JSONEncoder()
    var bad = try! JSONSerialization.jsonObject(with: enc.encode(good)) as! [String: Any]
    bad["id"] = "future"
    var deaths = bad["deaths"] as! [[String: Any]]
    deaths[0]["time"] = "not a number"
    bad["deaths"] = deaths
    let goodObj = try! JSONSerialization.jsonObject(with: enc.encode(good))
    let data = try! JSONSerialization.data(withJSONObject: [goodObj, bad])
    try? data.write(to: store.directory.appendingPathComponent("records.json"))
}
